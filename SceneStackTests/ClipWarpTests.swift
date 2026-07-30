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

    func testAsyncWarpMatchesTheSynchronousOne() async {
        let sync = clip(frames: 24_000, nativeTempo: 120)
        let async = clip(frames: 24_000, nativeTempo: 120)
        sync.applyTempo(90)
        await async.warp(to: 90)
        XCTAssertEqual(Int(async.buffer.frameLength), Int(sync.buffer.frameLength))
    }

    func testAsyncWarpAtNativeTempoUsesSourceUntouched() async {
        let c = clip(frames: 24_000, nativeTempo: 120)
        await c.warp(to: 120)
        XCTAssertTrue(c.buffer === c.sourceBuffer)
    }

    // MARK: - warp cache

    func testRepeatingATempoReusesTheCachedWarp() {
        // Re-rendering costs tens of milliseconds, so a tempo the clip has
        // already been warped to must come back as the identical buffer.
        let c = clip(frames: 24_000, nativeTempo: 120)
        c.applyTempo(132)
        let firstWarp = c.buffer
        c.applyTempo(120)
        XCTAssertTrue(c.buffer === c.sourceBuffer)
        c.applyTempo(132)
        XCTAssertTrue(c.buffer === firstWarp, "returning to 132 should reuse the cached render")
    }

    func testAsyncWarpSharesTheCacheWithTheSynchronousOne() async {
        let c = clip(frames: 24_000, nativeTempo: 120)
        c.applyTempo(132)
        let firstWarp = c.buffer
        c.applyTempo(120)
        await c.warp(to: 132)
        XCTAssertTrue(c.buffer === firstWarp, "both entry points share one cache")
    }

    func testCacheIsBoundedSoClipsDoNotGrowWithoutLimit() {
        // Each entry costs as much memory as the clip's audio, so the cache
        // holds only the most recent couple of tempos.
        let c = clip(frames: 24_000, nativeTempo: 120)
        c.applyTempo(132)
        let oldest = c.buffer
        c.applyTempo(140)
        c.applyTempo(150)
        c.applyTempo(132)
        XCTAssertFalse(c.buffer === oldest, "the oldest entry should have been evicted")
        XCTAssertEqual(Int(c.buffer.frameLength), Int(oldest.frameLength),
                       "but a re-render still produces the same length")
    }
}
