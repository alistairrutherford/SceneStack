import XCTest
import AVFoundation
@testable import SceneStack

/// Verifies the metronome — the transport's sample clock — actually places its
/// clicks on the beat, by rendering it through `AVAudioEngine`'s offline
/// manual-rendering mode and measuring the click onsets in the output samples.
///
/// This is the deterministic, device-free timing check the original plan asked
/// for: no real audio hardware, no wall-clock timing, just "render N beats and
/// assert every click lands on its bar/beat boundary".
final class MetronomeTimingTests: XCTestCase {

    private let sampleRate = 48_000.0

    /// Renders `beats` beats of the metronome at `tempo` and returns the frame
    /// index of each click onset (first sample of each beat that crosses an
    /// audible threshold).
    private func clickOnsets(tempo: Double, beats: Int) throws -> (onsets: [Int], framesPerBeat: Double) {
        let metronome = MetronomeSource(sampleRate: sampleRate)
        let engine = AVAudioEngine()
        engine.attach(metronome.node)
        // Mono source into the mixer; render out in stereo and read the left.
        engine.connect(metronome.node, to: engine.mainMixerNode, format: metronome.node.outputFormat(forBus: 0))

        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
        try engine.start()

        metronome.setTempo(tempo)
        metronome.setBeatsPerBar(4)
        metronome.setVolume(0.9)
        metronome.setClickAudible(true)
        metronome.setClickSuppressed(false)
        // A non-zero host time: in offline rendering the buffer host time is 0,
        // so the metronome starts at frame 0 (no pre-roll delay to subtract).
        metronome.start(countInBeats: 0, atHostTime: 1)

        let framesPerBeat = 60.0 / tempo * sampleRate
        let totalFrames = Int((Double(beats) * framesPerBeat).rounded())

        let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat,
                                      frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var samples: [Float] = []
        samples.reserveCapacity(totalFrames)
        var remaining = totalFrames
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(remaining, Int(engine.manualRenderingMaximumFrameCount)))
            let status = try engine.renderOffline(frames, to: buffer)
            XCTAssertEqual(status, .success)
            let channel = buffer.floatChannelData![0]
            for frame in 0..<Int(buffer.frameLength) { samples.append(channel[frame]) }
            remaining -= Int(buffer.frameLength)
        }
        engine.stop()

        // Onset = first frame above the audible threshold; skip half a beat
        // past each hit so the click's own decay/oscillation isn't re-counted.
        var onsets: [Int] = []
        var index = 0
        while index < samples.count {
            if abs(samples[index]) > 0.05 {
                onsets.append(index)
                index += Int(framesPerBeat / 2)
            } else {
                index += 1
            }
        }
        return (onsets, framesPerBeat)
    }

    func testClicksLandOnBeatBoundariesAt120BPM() throws {
        let (onsets, framesPerBeat) = try clickOnsets(tempo: 120, beats: 8)
        XCTAssertEqual(onsets.count, 8, "expected one click per beat")
        for (beat, onset) in onsets.enumerated() {
            let expected = Int((Double(beat) * framesPerBeat).rounded())
            // The sine ramps from zero, so the threshold is crossed a few
            // samples after the true boundary — never before it.
            XCTAssert(onset >= expected && onset - expected <= 64,
                      "beat \(beat): click at \(onset), expected ≈ \(expected)")
        }
    }

    func testClickSpacingScalesWithTempo() throws {
        // At 90 BPM the beat is 32000 frames at 48 kHz (vs 24000 at 120), so
        // the measured spacing must track the tempo, not stay fixed.
        let (onsets, framesPerBeat) = try clickOnsets(tempo: 90, beats: 6)
        XCTAssertEqual(onsets.count, 6)
        XCTAssertEqual(framesPerBeat, 32_000, accuracy: 1e-6)
        for pair in zip(onsets, onsets.dropFirst()) {
            let spacing = pair.1 - pair.0
            XCTAssertEqual(Double(spacing), framesPerBeat, accuracy: 64)
        }
    }

    func testSuppressedClickIsSilentButCountInStillSounds() throws {
        // Recording suppresses post-count-in clicks so they don't bleed into
        // the mic. With a 4-beat count-in and suppression on, the count-in
        // beats sound and the beats after beat zero fall silent.
        let metronome = MetronomeSource(sampleRate: sampleRate)
        let engine = AVAudioEngine()
        engine.attach(metronome.node)
        engine.connect(metronome.node, to: engine.mainMixerNode, format: metronome.node.outputFormat(forBus: 0))
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
        try engine.start()

        metronome.setTempo(120)
        metronome.setBeatsPerBar(4)
        metronome.setVolume(0.9)
        metronome.setClickAudible(true)
        metronome.setClickSuppressed(true)
        metronome.start(countInBeats: 4, atHostTime: 1)

        let framesPerBeat = 60.0 / 120.0 * sampleRate
        let totalFrames = Int(8 * framesPerBeat) // 4 count-in beats + 4 played
        let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat,
                                      frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var samples: [Float] = []
        var remaining = totalFrames
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(remaining, Int(engine.manualRenderingMaximumFrameCount)))
            _ = try engine.renderOffline(frames, to: buffer)
            let channel = buffer.floatChannelData![0]
            for frame in 0..<Int(buffer.frameLength) { samples.append(channel[frame]) }
            remaining -= Int(buffer.frameLength)
        }
        engine.stop()

        var onsets: [Int] = []
        var index = 0
        while index < samples.count {
            if abs(samples[index]) > 0.05 {
                onsets.append(index)
                index += Int(framesPerBeat / 2)
            } else {
                index += 1
            }
        }
        // Only the four count-in clicks should sound; suppression silences the
        // rest of the render.
        XCTAssertEqual(onsets.count, 4, "only count-in beats should click when suppressed")
        for onset in onsets {
            XCTAssertLessThan(onset, Int(4 * framesPerBeat), "audible click after count-in")
        }
    }
}
