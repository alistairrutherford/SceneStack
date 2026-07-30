import AVFoundation
import XCTest
@testable import SceneStack

/// `ClipLauncher` ends an outgoing clip by scheduling a fade with
/// `.interrupts` at the boundary time, rather than calling `stop()` from a
/// main-thread task that wakes whenever it wakes. That rests on two
/// `AVAudioPlayerNode` behaviours which are Apple's, not ours:
///
/// 1. `.interrupts` with a future time truncates at *that time*, not immediately;
/// 2. an interrupted looping buffer does not resume once the new buffer ends.
///
/// If either ever changed, clip switching would quietly go back to overlapping
/// audio with nothing else in the suite noticing — so they are pinned here.
/// Rendered offline, so this is deterministic and needs no audio hardware.
final class PlayerNodeInterruptTests: XCTestCase {

    private let sampleRate = 48000.0

    private func constantBuffer(_ value: Float, frames: AVAudioFrameCount,
                                format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = value }
        return buffer
    }

    /// Renders `frames` of a player that loops `1.0` and is interrupted by a
    /// buffer of `-1.0` scheduled at `interruptFrame`.
    private func renderInterruptedLoop(interruptFrame: AVAudioFramePosition,
                                       tailFrames: AVAudioFrameCount,
                                       totalFrames: Int) throws -> [Float] {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        try engine.start()
        defer { engine.stop() }

        player.scheduleBuffer(constantBuffer(1.0, frames: 100, format: format),
                              at: nil, options: [.loops], completionHandler: nil)
        player.play()
        player.scheduleBuffer(constantBuffer(-1.0, frames: tailFrames, format: format),
                              at: AVAudioTime(sampleTime: interruptFrame, atRate: sampleRate),
                              options: [.interrupts], completionHandler: nil)

        let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        var samples: [Float] = []
        while samples.count < totalFrames {
            let need = AVAudioFrameCount(min(256, totalFrames - samples.count))
            guard try engine.renderOffline(need, to: scratch) == .success,
                  scratch.frameLength > 0 else { break }
            for frame in 0..<Int(scratch.frameLength) {
                samples.append(scratch.floatChannelData![0][frame])
            }
        }
        return samples
    }

    func testInterruptTruncatesTheLoopAtTheScheduledFrameNotImmediately() throws {
        let samples = try renderInterruptedLoop(interruptFrame: 500, tailFrames: 200,
                                                totalFrames: 1000)

        XCTAssertEqual(samples.count, 1000)
        XCTAssertEqual(samples.firstIndex { $0 < -0.5 }, 500,
                       "the interrupting buffer must start exactly at the scheduled frame")
        // Everything before the boundary is still the loop, at full level.
        XCTAssertTrue(samples[0..<500].allSatisfy { $0 > 0.5 },
                      "the loop must keep playing untouched up to the boundary")
    }

    func testInterruptedLoopDoesNotResumeAfterTheNewBufferEnds() throws {
        let samples = try renderInterruptedLoop(interruptFrame: 500, tailFrames: 200,
                                                totalFrames: 1000)

        // 500..<700 is the interrupting buffer; everything after it is silence,
        // which is what lets a short fade stand in for stopping the player.
        XCTAssertTrue(samples[700...].allSatisfy { abs($0) < 0.01 },
                      "the interrupted loop must not come back once the tail ends")
    }
}
