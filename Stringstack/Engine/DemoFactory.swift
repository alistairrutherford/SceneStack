import AVFoundation
import Foundation

/// Builds the welcome/demo set: four synthesised loops dropped into the
/// session grid, plus a small arrangement, so a first launch has something
/// to play with immediately. All audio is generated mathematically — no
/// bundled assets.
@MainActor
enum DemoFactory {

    static func install(into engine: TransportEngine) {
        // Replace the session outright, exactly as New Project does, so
        // reloading the demo starts from a clean grid instead of layering its
        // clips onto whatever scenes and tracks are already there.
        let names = ["Drums", "Bass", "Keys", "Shaker"]
        let fresh = names.enumerated().map { index, name in
            Track(name: name, colorIndex: index % 6, sceneCount: 4)
        }
        engine.replaceSession(tempo: 112, beatsPerBar: 4, countInBars: 2, quantize: .bar,
                              sceneCount: 4, masterVolume: 0.9, newTracks: fresh)
        // The demo isn't the user's saved project — don't let ⌘S overwrite it.
        engine.projectURL = nil

        let format = engine.standardFormat
        let tempo = engine.tempo

        let specs: [(track: Int, name: String, bars: Int,
                     voice: (Double, Double, inout UInt64) -> Double)] = [
            (0, "Beat", 2, drums),
            (1, "Bassline", 2, bass),
            (2, "Am Pad", 4, keys),
            (3, "Shaker 16s", 1, shaker),
        ]

        for spec in specs {
            guard let buffer = render(bars: spec.bars, beatsPerBar: engine.beatsPerBar,
                                      tempo: tempo, format: format, voice: spec.voice) else { continue }
            let track = engine.tracks[spec.track]
            let clip = Clip(name: spec.name, colorIndex: track.colorIndex,
                            buffer: buffer, loopBars: spec.bars, fileURL: nil,
                            nativeTempo: tempo)
            track.slots[0] = clip
        }

        engine.selectedTrackID = engine.tracks.first?.id
        engine.statusMessage = "Demo set loaded — press a scene ▶ or space to play."
    }

    // MARK: - Render skeleton

    /// Renders a loop by evaluating `voice(beatPosition, secondsPerBeat, rng)`
    /// per frame, written identically to both channels.
    private static func render(bars: Int, beatsPerBar: Int, tempo: Double,
                               format: AVAudioFormat,
                               voice: (Double, Double, inout UInt64) -> Double) -> AVAudioPCMBuffer? {
        let secondsPerBeat = 60.0 / tempo
        let framesPerBeat = secondsPerBeat * format.sampleRate
        let totalBeats = bars * beatsPerBar
        let frameCount = AVAudioFrameCount((Double(totalBeats) * framesPerBeat).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount

        var rng: UInt64 = 0x9E3779B97F4A7C15
        for frame in 0..<Int(frameCount) {
            let beat = Double(frame) / framesPerBeat
            let sample = Float(max(-1, min(1, voice(beat, secondsPerBeat, &rng))))
            data[0][frame] = sample
            data[1][frame] = sample
        }
        return buffer
    }

    private static func noise(_ state: inout UInt64) -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 2_000_000) / 1_000_000 - 1
    }

    // MARK: - Voices

    /// Four-on-the-floor kick, snare on 2 and 4, eighth-note hats.
    private static func drums(beat: Double, secondsPerBeat: Double, rng: inout UInt64) -> Double {
        var sample = 0.0

        let kickTime = beat.truncatingRemainder(dividingBy: 1) * secondsPerBeat
        let sweep = 42 * kickTime + (130 / 35) * (1 - exp(-35 * kickTime))
        sample += sin(2 * .pi * sweep) * exp(-6 * kickTime) * 0.9

        let snarePhase = beat.truncatingRemainder(dividingBy: 2)
        if snarePhase >= 1 {
            let snareTime = (snarePhase - 1) * secondsPerBeat
            sample += noise(&rng) * exp(-18 * snareTime) * 0.4
        }

        let hatTime = beat.truncatingRemainder(dividingBy: 0.5) * secondsPerBeat
        sample += noise(&rng) * exp(-55 * hatTime) * 0.16

        return sample
    }

    /// Eighth-note minor-pentatonic bassline over A1.
    private static func bass(beat: Double, secondsPerBeat: Double, rng: inout UInt64) -> Double {
        let pattern: [Double] = [0, 0, 12, 0, 3, 3, 5, 3, 0, 0, 12, 7, 5, 3, 2, 3]
        let step = Int(beat * 2) % pattern.count
        let frequency = 55.0 * pow(2, pattern[step] / 12)
        let stepTime = (beat * 2).truncatingRemainder(dividingBy: 1) * secondsPerBeat / 2
        let envelope = exp(-3.5 * stepTime)
        let tone = tanh(2.2 * sin(2 * .pi * frequency * stepTime))
            + 0.25 * sin(2 * .pi * frequency * 2 * stepTime)
        return tone * envelope * 0.34
    }

    /// Slowly swelling detuned Am7 pad with gentle tremolo.
    private static func keys(beat: Double, secondsPerBeat: Double, rng: inout UInt64) -> Double {
        let time = beat * secondsPerBeat
        let chord = [220.0, 261.63, 329.63, 392.0]
        var sample = 0.0
        for frequency in chord {
            sample += sin(2 * .pi * frequency * 1.0009 * time)
            sample += sin(2 * .pi * frequency * 0.9991 * time)
        }
        let attack = min(1, time / 0.6)
        let tremolo = 0.8 + 0.2 * sin(2 * .pi * 0.9 * time)
        return sample * 0.028 * attack * tremolo
    }

    /// Sixteenth-note shaker with accent alternation.
    private static func shaker(beat: Double, secondsPerBeat: Double, rng: inout UInt64) -> Double {
        let sixteenthTime = beat.truncatingRemainder(dividingBy: 0.25) * secondsPerBeat
        let accent = Int(beat * 4) % 2 == 0 ? 0.22 : 0.10
        return noise(&rng) * exp(-45 * sixteenthTime) * accent
    }
}
