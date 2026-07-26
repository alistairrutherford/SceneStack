import AVFoundation
import Accelerate
import Synchronization

/// Stereo peak meter fed by a node tap. Values are smoothed with a decay so
/// the UI can poll at frame rate.
final class MeterTap: @unchecked Sendable {
    private let leftBits = Atomic<UInt64>(0.0.bitPattern)
    private let rightBits = Atomic<UInt64>(0.0.bitPattern)

    var levels: (left: Double, right: Double) {
        (Double(bitPattern: leftBits.load(ordering: .relaxed)),
         Double(bitPattern: rightBits.load(ordering: .relaxed)))
    }

    func install(on node: AVAudioNode) {
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let channelCount = Int(buffer.format.channelCount)
            var peaks: [Float] = [0, 0]
            for channel in 0..<min(2, channelCount) {
                vDSP_maxmgv(data[channel], 1, &peaks[channel], vDSP_Length(buffer.frameLength))
            }
            if channelCount == 1 { peaks[1] = peaks[0] }

            let previous = self.levels
            self.leftBits.store(max(Double(peaks[0]), previous.left * 0.86).bitPattern, ordering: .relaxed)
            self.rightBits.store(max(Double(peaks[1]), previous.right * 0.86).bitPattern, ordering: .relaxed)
        }
    }
}
