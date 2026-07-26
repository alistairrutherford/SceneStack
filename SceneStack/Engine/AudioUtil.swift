import AVFoundation

enum AudioUtil {
    /// Converts a buffer to the given format (sample rate / channel count),
    /// returning the original if it already matches.
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return conversionError == nil ? output : nil
    }

    /// Sums `overlay` onto a copy of `base` (for overdub), clamped to
    /// [-1, 1]. Result length matches `base`; `overlay` is added where the
    /// two overlap. Both are assumed to share `base`'s format.
    static func mix(base: AVAudioPCMBuffer, overlay: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let baseData = base.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: base.format, frameCapacity: base.frameLength),
              let outData = out.floatChannelData else { return nil }
        out.frameLength = base.frameLength
        let channels = Int(base.format.channelCount)
        let baseFrames = Int(base.frameLength)
        for channel in 0..<channels {
            outData[channel].update(from: baseData[channel], count: baseFrames)
        }
        if let overlayData = overlay.floatChannelData {
            let overlayFrames = min(baseFrames, Int(overlay.frameLength))
            let overlayChannels = Int(overlay.format.channelCount)
            for channel in 0..<channels {
                let source = overlayData[min(channel, overlayChannels - 1)]
                for frame in 0..<overlayFrames {
                    var sample = outData[channel][frame] + source[frame]
                    sample = max(-1, min(1, sample))
                    outData[channel][frame] = sample
                }
            }
        }
        return out
    }

    /// Linearly resamples `buffer` to exactly `targetFrames` frames, keeping the
    /// same format. Used for clip warping: playing a loop's audio into a
    /// different frame count changes its speed (and pitch — this is the simple,
    /// no-time-stretch version) so it spans the same bars at a new tempo.
    static func resample(_ buffer: AVAudioPCMBuffer, toFrames targetFrames: Int) -> AVAudioPCMBuffer? {
        guard targetFrames > 0,
              let source = buffer.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                            frameCapacity: AVAudioFrameCount(targetFrames)),
              let destination = output.floatChannelData else { return nil }
        output.frameLength = AVAudioFrameCount(targetFrames)
        let channels = Int(buffer.format.channelCount)
        let sourceFrames = Int(buffer.frameLength)

        // Degenerate sources: nothing to interpolate between.
        guard sourceFrames > 1 else {
            for channel in 0..<channels {
                let value = sourceFrames == 1 ? source[channel][0] : 0
                for frame in 0..<targetFrames { destination[channel][frame] = value }
            }
            return output
        }

        // Map each output frame back to a fractional source position and lerp.
        // The buffer is treated as periodic (these clips loop), so the sample
        // after the last wraps to the first — the loop seam stays continuous.
        let step = Double(sourceFrames) / Double(targetFrames)
        for channel in 0..<channels {
            let src = source[channel]
            let dst = destination[channel]
            for frame in 0..<targetFrames {
                let position = Double(frame) * step
                let index = Int(position) % sourceFrames
                let next = (index + 1) % sourceFrames
                let fraction = Float(position - Double(Int(position)))
                dst[frame] = src[index] + fraction * (src[next] - src[index])
            }
        }
        return output
    }

    /// Copies `frames` frames starting at `start` into a new buffer.
    static func slice(_ buffer: AVAudioPCMBuffer, from start: Int, frames: Int) -> AVAudioPCMBuffer? {
        guard frames > 0, start >= 0, start + frames <= Int(buffer.frameLength),
              let source = buffer.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData else { return nil }
        output.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel] + start, count: frames)
        }
        return output
    }
}
