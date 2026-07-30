import AVFoundation
import XCTest
@testable import SceneStack

/// A tempo change re-warps every clip in the session, and each warp is tens of
/// milliseconds of offline DSP. Run on the main actor that froze the UI for as
/// long as it took — measured at ~390 ms for eight 4-second clips, and 1.5 s
/// for thirty-two. The renders now happen off the main actor, so this measures
/// what the main actor actually experiences while a session re-warps.
final class TempoWarpResponsivenessTests: XCTestCase {

    /// Samples how long the main actor goes unavailable, by trying to run
    /// often and recording the largest gap between successive turns.
    @MainActor
    private final class MainActorProbe {
        private var lastTick = Date()
        private(set) var longestStall: TimeInterval = 0
        private var task: Task<Void, Never>?

        func start() {
            lastTick = Date()
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    guard let self else { return }
                    let now = Date()
                    self.longestStall = max(self.longestStall, now.timeIntervalSince(self.lastTick))
                    self.lastTick = now
                }
            }
        }

        func stop() { task?.cancel() }
    }

    /// Four seconds of audio at the engine's format — the size the timings in
    /// the doc comment were measured against.
    @MainActor
    private func makeClip(seconds: Double, nativeTempo: Double,
                          in engine: TransportEngine) -> Clip {
        let format = engine.standardFormat
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                data[frame] = sin(Float(frame) * 0.01) * 0.5
            }
        }
        return Clip(name: "Warp me", colorIndex: 0, buffer: buffer, loopBars: 2,
                    fileURL: nil, nativeTempo: nativeTempo)
    }

    @MainActor
    func testTempoChangeReWarpsTheSessionWithoutBlockingTheMainActor() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil, "no usable audio here")

        // Eight 4-second clips, all needing a real warp when the tempo moves.
        engine.addScene()
        engine.addScene()
        engine.addScene()
        engine.addScene()
        var clips: [Clip] = []
        for track in engine.tracks.prefix(4) {
            for scene in 0..<2 {
                let clip = makeClip(seconds: 4, nativeTempo: 120, in: engine)
                track.slots[scene] = clip
                clips.append(clip)
            }
        }
        XCTAssertEqual(clips.count, 8)
        XCTAssertTrue(clips.allSatisfy { $0.buffer === $0.sourceBuffer })

        let probe = MainActorProbe()
        probe.start()
        engine.tempo = 132               // schedules the debounced re-warp
        // 200 ms debounce, then eight renders of ~50 ms each.
        try await Task.sleep(nanoseconds: 1_600_000_000)
        probe.stop()

        // The warp actually happened: 120 → 132 shortens each loop by 120/132.
        for clip in clips {
            let expected = Int((Double(clip.sourceBuffer.frameLength) * 120.0 / 132.0).rounded())
            XCTAssertEqual(Int(clip.buffer.frameLength), expected, accuracy: 2)
            XCTAssertFalse(clip.buffer === clip.sourceBuffer)
        }

        // And the main actor stayed available throughout. Rendering these eight
        // clips inline would have blocked it for ~390 ms in one go.
        XCTAssertLessThan(probe.longestStall, 0.080,
                          "main actor stalled for \(probe.longestStall * 1000) ms during the re-warp")
        print(String(format: "longest main-actor stall during an 8-clip re-warp: %.1f ms",
                     probe.longestStall * 1000))
    }
}
