import AVFoundation

/// Carries an audio buffer across an isolation boundary.
///
/// `AVAudioPCMBuffer` isn't `Sendable`, but the buffers sent through here are
/// safe to move: a clip's source audio is immutable once created, and a warp
/// result is freshly rendered with no other reference to it until the main
/// actor takes ownership.
struct AudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

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

    /// Time-stretches `buffer` to exactly `targetFrames` frames **keeping the
    /// pitch constant** (the Ableton-style warp), using Apple's offline
    /// `AVAudioUnitTimePitch`. Returns nil if the stretcher can't run so the
    /// caller can fall back to `resample`.
    ///
    /// Loop-seam handling: the source is rendered *looped*, and a
    /// `targetFrames`-long window is taken from the steady state (past the
    /// stretcher's priming ramp). Because the looped, stretched output is
    /// periodic with period `targetFrames`, that window is exactly one loop
    /// cycle whose end meets its start — so it loops without a seam click.
    static func timeStretch(_ buffer: AVAudioPCMBuffer, toFrames targetFrames: Int) -> AVAudioPCMBuffer? {
        guard targetFrames > 0 else { return nil }
        let sourceFrames = Int(buffer.frameLength)
        guard sourceFrames > 1 else { return nil }

        let format = buffer.format
        // rate > 1 → faster/shorter output; must sit in the AU's valid range.
        let rate = Double(sourceFrames) / Double(targetFrames)
        guard rate >= 1.0 / 32, rate <= 32 else { return nil }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(rate)   // pitch left at 0 cents → pitch preserved
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4096
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
            try engine.start()
        } catch {
            return nil
        }
        defer { engine.stop() }

        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        player.play()

        // Skip past the stretcher's priming ramp so the window is steady-state.
        let latencyFrames = Int((timePitch.latency) * format.sampleRate)
        let skip = latencyFrames + 4096
        let totalToRender = skip + targetFrames

        guard let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(targetFrames)),
              let render = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else {
            return nil
        }
        out.frameLength = AVAudioFrameCount(targetFrames)
        let channels = Int(format.channelCount)

        var rendered = 0
        var written = 0
        while rendered < totalToRender, written < targetFrames {
            let need = min(Int(maxFrames), totalToRender - rendered)
            let status = (try? engine.renderOffline(AVAudioFrameCount(need), to: render)) ?? .error
            guard status == .success, render.frameLength > 0 else { break }
            let got = Int(render.frameLength)
            for local in 0..<got {
                let absolute = rendered + local
                if absolute < skip { continue }
                if written >= targetFrames { break }
                for channel in 0..<channels {
                    out.floatChannelData![channel][written] = render.floatChannelData![channel][local]
                }
                written += 1
            }
            rendered += got
        }

        guard written > 0 else { return nil }
        // Pad any shortfall by wrapping, so the loop length stays exact.
        if written < targetFrames {
            for channel in 0..<channels {
                let data = out.floatChannelData![channel]
                for frame in written..<targetFrames { data[frame] = data[frame % written] }
            }
        }
        return out
    }

    /// A short fade-to-silence lifted from `buffer` starting at `startFrame`,
    /// wrapping at the end (these buffers are loops, so the audio after the
    /// last frame is the first).
    ///
    /// Scheduled with `.interrupts` at a launch/stop boundary this ends a
    /// looping clip *on* the beat: the fade begins at full level, so it picks
    /// up exactly where the loop was, and decays over a few milliseconds
    /// instead of cutting mid-waveform the way `stop()` does.
    static func fadeOutTail(_ buffer: AVAudioPCMBuffer,
                            fromFrame startFrame: Int,
                            frames: Int) -> AVAudioPCMBuffer? {
        let sourceFrames = Int(buffer.frameLength)
        guard frames > 0, sourceFrames > 0,
              let source = buffer.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData else { return nil }
        output.frameLength = AVAudioFrameCount(frames)

        // Wrap into range for any start frame, including a negative one.
        let start = ((startFrame % sourceFrames) + sourceFrames) % sourceFrames
        for channel in 0..<Int(buffer.format.channelCount) {
            let src = source[channel]
            let dst = destination[channel]
            for frame in 0..<frames {
                // Full level on the first frame → continuous with the loop.
                let gain = Float(frames - frame) / Float(frames)
                dst[frame] = src[(start + frame) % sourceFrames] * gain
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
