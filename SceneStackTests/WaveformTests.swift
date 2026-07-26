import XCTest
import AVFoundation
@testable import SceneStack

/// Waveform peak downsampling used for clip thumbnails and the inspector.
final class WaveformTests: XCTestCase {

    private func buffer(_ values: [Float], sampleRate: Double = 48000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
        buf.frameLength = AVAudioFrameCount(values.count)
        for frame in values.indices { buf.floatChannelData![0][frame] = values[frame] }
        return buf
    }

    func testConstantSignalNormalisesToFull() {
        let peaks = Waveform.peaks(for: buffer(Array(repeating: 0.5, count: 100)), bins: 10)
        XCTAssertEqual(peaks.count, 10)
        for value in peaks { XCTAssertEqual(value, 1.0, accuracy: 1e-5) }
    }

    func testSilenceStaysZero() {
        let peaks = Waveform.peaks(for: buffer(Array(repeating: 0, count: 100)), bins: 10)
        XCTAssertEqual(peaks.count, 10)
        for value in peaks { XCTAssertEqual(value, 0, accuracy: 1e-6) }
    }

    func testPeaksAreNonNegativeAndBounded() {
        var ramp = [Float]()
        for i in 0..<200 {
            let magnitude = Float(i) / 200
            ramp.append(i % 2 == 0 ? magnitude : -magnitude)
        }
        let peaks = Waveform.peaks(for: buffer(ramp), bins: 24)
        XCTAssertFalse(peaks.isEmpty)
        for value in peaks {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1.0001)
        }
    }

    func testLoudestBinReachesOne() {
        // A spike in one region should normalise that region's bin to 1.
        var values = Array(repeating: Float(0.1), count: 100)
        values[50] = 0.9
        let peaks = Waveform.peaks(for: buffer(values), bins: 10)
        XCTAssertEqual(peaks.max() ?? 0, 1.0, accuracy: 1e-5)
    }
}
