import AVFoundation
import Accelerate

enum Waveform {
    /// Downsamples a buffer to `bins` peak values (0...1), normalised so
    /// quiet takes still show their shape in clip thumbnails.
    static func peaks(for buffer: AVAudioPCMBuffer, bins: Int) -> [Float] {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0, bins > 0 else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let binSize = max(1, frames / bins)

        var peaks: [Float] = []
        peaks.reserveCapacity(bins)
        for bin in 0..<bins {
            let start = bin * binSize
            guard start < frames else { break }
            let count = min(binSize, frames - start)
            var binPeak: Float = 0
            for channel in 0..<channels {
                var channelPeak: Float = 0
                vDSP_maxmgv(data[channel] + start, 1, &channelPeak, vDSP_Length(count))
                binPeak = max(binPeak, channelPeak)
            }
            peaks.append(binPeak)
        }

        if let maxPeak = peaks.max(), maxPeak > 0.001 {
            peaks = peaks.map { $0 / maxPeak }
        }
        return peaks
    }
}
