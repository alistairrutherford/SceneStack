import XCTest
import AVFoundation
@testable import SceneStack

/// Buffer maths used by overdub (mix), loop tiling (slice), and format
/// normalisation (convert).
final class AudioUtilTests: XCTestCase {

    private func buffer(_ values: [Float], channels: AVAudioChannelCount = 1,
                        sampleRate: Double = 48000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
        buf.frameLength = AVAudioFrameCount(values.count)
        for channel in 0..<Int(channels) {
            for frame in values.indices { buf.floatChannelData![channel][frame] = values[frame] }
        }
        return buf
    }

    private func channelSamples(_ buffer: AVAudioPCMBuffer, channel: Int = 0) -> [Float] {
        let ptr = buffer.floatChannelData![channel]
        return (0..<Int(buffer.frameLength)).map { ptr[$0] }
    }

    private func assertClose(_ a: [Float], _ b: [Float],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, "sample count", file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x, y, accuracy: 1e-6, file: file, line: line)
        }
    }

    // MARK: - mix (overdub sum)

    func testMixSumsSamples() throws {
        let out = try XCTUnwrap(AudioUtil.mix(base: buffer([0.25, 0.5]),
                                              overlay: buffer([0.25, 0.1])))
        assertClose(channelSamples(out), [0.5, 0.6])
    }

    func testMixClampsToUnity() throws {
        let out = try XCTUnwrap(AudioUtil.mix(base: buffer([0.8, -0.8]),
                                              overlay: buffer([0.8, -0.8])))
        assertClose(channelSamples(out), [1.0, -1.0])
    }

    func testMixResultLengthMatchesBaseAndPadsShortOverlay() throws {
        let out = try XCTUnwrap(AudioUtil.mix(base: buffer([0.2, 0.2, 0.2]),
                                              overlay: buffer([0.5])))
        XCTAssertEqual(out.frameLength, 3)
        assertClose(channelSamples(out), [0.7, 0.2, 0.2])
    }

    // MARK: - slice

    func testSliceCopiesRange() throws {
        let out = try XCTUnwrap(AudioUtil.slice(buffer([1, 2, 3, 4, 5]), from: 1, frames: 3))
        assertClose(channelSamples(out), [2, 3, 4])
    }

    func testSliceRejectsOutOfBounds() {
        XCTAssertNil(AudioUtil.slice(buffer([1, 2, 3]), from: 2, frames: 5))
        XCTAssertNil(AudioUtil.slice(buffer([1, 2, 3]), from: 0, frames: 0))
        XCTAssertNil(AudioUtil.slice(buffer([1, 2, 3]), from: -1, frames: 2))
    }

    // MARK: - resample (clip warping)

    func testResampleProducesExactTargetLength() throws {
        let out = try XCTUnwrap(AudioUtil.resample(buffer([0, 0.5, 1, 0.5]), toFrames: 8))
        XCTAssertEqual(out.frameLength, 8)
    }

    func testResampleUpsamplesWithLinearInterpolation() throws {
        // [0, 1] treated as periodic, upsampled to 4 frames:
        // positions 0, 0.5, 1.0, 1.5 → 0, 0.5, 1, 0.5 (last lerps back to start).
        let out = try XCTUnwrap(AudioUtil.resample(buffer([0, 1]), toFrames: 4))
        assertClose(channelSamples(out), [0, 0.5, 1, 0.5])
    }

    func testResampleConstantSignalStaysConstant() throws {
        let out = try XCTUnwrap(AudioUtil.resample(buffer([0.3, 0.3, 0.3]), toFrames: 7))
        assertClose(channelSamples(out), Array(repeating: 0.3, count: 7))
    }

    func testResampleHalvingLengthMatchesTempoDoubling() throws {
        // A 4-frame loop resampled to 2 frames (as a 2× tempo warp would do).
        let out = try XCTUnwrap(AudioUtil.resample(buffer([0, 1, 2, 3]), toFrames: 2))
        XCTAssertEqual(out.frameLength, 2)
        assertClose(channelSamples(out), [0, 2])
    }

    func testResampleRejectsZeroTarget() {
        XCTAssertNil(AudioUtil.resample(buffer([1, 2, 3]), toFrames: 0))
    }

    // MARK: - convert

    func testConvertReturnsSameBufferWhenFormatMatches() {
        let input = buffer([0.1, 0.2], channels: 2)
        XCTAssertTrue(AudioUtil.convert(input, to: input.format) === input)
    }

    func testConvertResamplesToTargetRate() throws {
        let input = buffer(Array(repeating: 0.3, count: 48000), sampleRate: 48000)
        let target = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let out = try XCTUnwrap(AudioUtil.convert(input, to: target))
        XCTAssertEqual(out.format.sampleRate, 24000)
        // Halving the rate ≈ halves the frame count (allow converter slack).
        XCTAssertLessThanOrEqual(abs(Int(out.frameLength) - 24000), 128)
    }
}
