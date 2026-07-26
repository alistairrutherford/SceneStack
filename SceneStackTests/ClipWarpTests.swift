import XCTest
import AVFoundation
@testable import SceneStack

/// Clip tempo-follow: warping resamples the source so the loop spans the same
/// bars at the project tempo (frame count scales by nativeTempo / tempo).
@MainActor
final class ClipWarpTests: XCTestCase {

    private func clip(frames: Int, nativeTempo: Double, loopBars: Int = 1) -> Clip {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for frame in 0..<frames { buffer.floatChannelData![channel][frame] = Float(frame % 8) / 8 }
        }
        return Clip(name: "Test", colorIndex: 0, buffer: buffer,
                    loopBars: loopBars, fileURL: nil, nativeTempo: nativeTempo)
    }

    func testNativeTempoUsesSourceUntouched() {
        let c = clip(frames: 24_000, nativeTempo: 120)
        c.applyTempo(120)
        XCTAssertTrue(c.buffer === c.sourceBuffer, "no warp at the native tempo")
    }

    func testHalvingTempoDoublesLength() {
        // Half the tempo → the loop must last twice as long → twice the frames.
        let c = clip(frames: 24_000, nativeTempo: 120)
        c.applyTempo(60)
        XCTAssertEqual(Int(c.buffer.frameLength), 48_000)
    }

    func testRaisingTempoShortensLength() {
        // 120 → 160 BPM: frames scale by 120/160 = 0.75.
        let c = clip(frames: 24_000, nativeTempo: 120)
        c.applyTempo(160)
        XCTAssertEqual(Int(c.buffer.frameLength), 18_000)
    }

    func testWarpIsReversibleBackToNative() {
        let c = clip(frames: 24_000, nativeTempo: 120)
        c.applyTempo(90)
        XCTAssertNotEqual(Int(c.buffer.frameLength), 24_000)
        c.applyTempo(120)
        XCTAssertTrue(c.buffer === c.sourceBuffer, "returning to native reuses the source")
    }
}
