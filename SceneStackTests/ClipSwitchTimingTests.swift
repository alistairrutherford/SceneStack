import AVFoundation
import XCTest
@testable import SceneStack

/// Measures what a real clip switch actually produces, by tapping the track's
/// mixer while the engine runs for real.
///
/// The incoming clip starts sample-accurately, so the thing worth measuring is
/// the outgoing one: it used to run at full level until a main-thread task woke
/// up and called `stop()` — an unbounded overlap ended by a step. It should now
/// be a short, bounded fade scheduled on the audio thread.
final class ClipSwitchTimingTests: XCTestCase {

    /// Collects tap buffers off the audio thread.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []

        func append(_ buffer: AVAudioPCMBuffer) {
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var chunk = [Float](repeating: 0, count: Int(buffer.frameLength))
            for frame in 0..<Int(buffer.frameLength) { chunk[frame] = data[0][frame] }
            lock.lock()
            samples.append(contentsOf: chunk)
            lock.unlock()
        }

        var collected: [Float] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }
    }

    /// A clip of constant `level`, exactly `bars` long at the engine's tempo,
    /// so two of them overlapping is visible as a doubled level.
    @MainActor
    private func makeConstantClip(_ level: Float, bars: Int,
                                  in engine: TransportEngine) -> Clip {
        let format = engine.standardFormat
        let seconds = Double(bars * engine.beatsPerBar) * 60.0 / engine.tempo
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) { data[frame] = level }
        }
        return Clip(name: "Constant", colorIndex: 0, buffer: buffer, loopBars: bars,
                    fileURL: nil, nativeTempo: engine.tempo)
    }

    @MainActor
    func testSwitchingClipsOverlapsOnlyForTheFadeAndDecaysSmoothly() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil,
                      "no usable audio output here: \(engine.engineError ?? "")")
        engine.masterVolume = 0          // keep the test quiet; the tap is upstream
        engine.tempo = 240               // a beat every 250 ms, so the test is short
        engine.quantize = .beat

        let track = engine.tracks[0]
        let first = makeConstantClip(0.5, bars: 1, in: engine)
        let second = makeConstantClip(0.5, bars: 1, in: engine)
        track.slots[0] = first
        track.slots[1] = second

        let channel = try XCTUnwrap(engine.graph.channel(for: track.id))
        let capture = Capture()
        let sampleRate = engine.standardFormat.sampleRate
        channel.inputMixer.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in
            capture.append(buffer)
        }
        defer { channel.inputMixer.removeTap(onBus: 0) }

        engine.launch(clip: first, on: track)
        try await Task.sleep(nanoseconds: 700_000_000)
        engine.launch(clip: second, on: track)
        try await Task.sleep(nanoseconds: 700_000_000)
        engine.stop()
        try await Task.sleep(nanoseconds: 100_000_000)

        let samples = capture.collected
        try XCTSkipIf(samples.isEmpty, "the tap captured nothing — no audio ran")

        // One clip alone sits at 0.5; both together reach 1.0. Anything above
        // the midpoint is the two clips sounding at once.
        let overlapping = samples.enumerated().filter { $0.element > 0.6 }.map(\.offset)
        XCTAssertFalse(overlapping.isEmpty,
                       "no transition was captured — the test measured nothing")

        let overlapStart = try XCTUnwrap(overlapping.first)
        let overlapEnd = try XCTUnwrap(overlapping.last)
        let overlapMilliseconds = Double(overlapEnd - overlapStart + 1) / sampleRate * 1000
        XCTAssertLessThan(overlapMilliseconds, 8.0,
                          "outgoing clip overlapped the incoming one for \(overlapMilliseconds) ms")

        // The sum never meaningfully exceeds two clips at full level, i.e. the
        // fade starts from the level the loop was already at.
        XCTAssertLessThan(try XCTUnwrap(samples.max()), 1.05)

        // Across the overlap the level should fall, not step: sample the
        // captured region and check it is decreasing overall.
        let region = Array(samples[overlapStart...overlapEnd])
        if region.count >= 8 {
            let head = region.prefix(region.count / 4).reduce(0, +) / Float(region.count / 4)
            let tail = region.suffix(region.count / 4).reduce(0, +) / Float(region.count / 4)
            XCTAssertGreaterThan(head, tail, "the outgoing clip should be fading, not cutting")
        }

        print("clip-switch overlap: \(String(format: "%.2f", overlapMilliseconds)) ms "
              + "(peak \(String(format: "%.3f", samples.max() ?? 0)))")
    }
}
