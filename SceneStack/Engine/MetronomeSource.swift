import AVFoundation
import Synchronization

/// Sample-accurate metronome click generator.
///
/// The render block runs on the real-time audio thread: it must never lock or
/// allocate, so all communication with the main thread goes through atomics.
/// The metronome is also the transport's sample clock — `currentBeats` is
/// derived from the number of frames rendered since the anchored start time.
/// Starts are anchored to a mach host time so that clip players scheduled
/// with `play(at:)` and the recording trim share the same beat-zero instant.
final class MetronomeSource: @unchecked Sendable {

    // Control — main thread writes, render thread reads.
    private let runningFlag = Atomic<Bool>(false)
    private let resetFlag = Atomic<Bool>(false)
    private let startHostTimeBits = Atomic<UInt64>(0)
    private let initialPhaseBits = Atomic<UInt64>(0.0.bitPattern)
    private let tempoBits = Atomic<UInt64>(120.0.bitPattern)
    private let beatsPerBarValue = Atomic<Int>(4)
    private let countInBeatsValue = Atomic<Int>(0)
    private let audibleFlag = Atomic<Bool>(true)
    private let suppressClickFlag = Atomic<Bool>(false)
    private let volumeBits = Atomic<UInt64>(0.7.bitPattern)

    // Feedback — render thread writes, main thread reads.
    private let beatPhaseBits = Atomic<UInt64>(0.0.bitPattern)

    // Render-thread-only state.
    private var beatPhase = 0.0
    private var lastBeatIndex = -1
    private var framesUntilStart = 0
    private var startPending = false
    private var oscPhase = 0.0
    private var oscFrequency = 0.0
    private var envelope = 0.0
    private let envelopeDecay: Double
    private let sampleRate: Double

    private(set) var node: AVAudioSourceNode!

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // ~45 ms exponential decay; squared in the render loop for a tighter click.
        self.envelopeDecay = exp(-1.0 / (0.045 * sampleRate))
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        node = AVAudioSourceNode(format: format) { [unowned self] _, timestamp, frameCount, audioBufferList in
            self.render(timestamp: timestamp, frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }

    // MARK: - Main-thread control

    /// Starts the clock at `fromBeat` minus `countInBeats`, with the first
    /// beat landing exactly at `hostTime`. `fromBeat` lets the arrangement
    /// view play from the playhead rather than the top.
    ///
    /// The raw phase runs from `fromBeat`; the count-in occupies phases
    /// `[fromBeat, fromBeat + countInBeats)` and `currentBeats` subtracts the
    /// count-in, so it reads negative until bar 1. (Adding `countInBeats`
    /// into the initial phase here would silently skip the count-in.)
    func start(countInBeats: Int, atHostTime hostTime: UInt64, fromBeat: Double = 0) {
        countInBeatsValue.store(countInBeats, ordering: .sequentiallyConsistent)
        startHostTimeBits.store(hostTime, ordering: .sequentiallyConsistent)
        initialPhaseBits.store(fromBeat.bitPattern, ordering: .sequentiallyConsistent)
        beatPhaseBits.store(fromBeat.bitPattern, ordering: .sequentiallyConsistent)
        resetFlag.store(true, ordering: .sequentiallyConsistent)
        runningFlag.store(true, ordering: .sequentiallyConsistent)
    }

    func stop() {
        runningFlag.store(false, ordering: .sequentiallyConsistent)
    }

    func setTempo(_ bpm: Double) { tempoBits.store(bpm.bitPattern, ordering: .relaxed) }
    func setBeatsPerBar(_ beats: Int) { beatsPerBarValue.store(beats, ordering: .relaxed) }
    func setClickAudible(_ audible: Bool) { audibleFlag.store(audible, ordering: .relaxed) }
    /// While recording, post-count-in clicks are muted so they don't bleed
    /// from the speakers into the mic take; count-in clicks always sound.
    func setClickSuppressed(_ suppressed: Bool) { suppressClickFlag.store(suppressed, ordering: .relaxed) }
    func setVolume(_ volume: Double) { volumeBits.store(volume.bitPattern, ordering: .relaxed) }

    /// Beats since the transport reached beat zero; negative during count-in.
    var currentBeats: Double {
        Double(bitPattern: beatPhaseBits.load(ordering: .relaxed))
            - Double(countInBeatsValue.load(ordering: .relaxed))
    }

    // MARK: - Render thread

    private func render(timestamp: UnsafePointer<AudioTimeStamp>,
                        frameCount: AVAudioFrameCount,
                        audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

        if resetFlag.exchange(false, ordering: .sequentiallyConsistent) {
            beatPhase = Double(bitPattern: initialPhaseBits.load(ordering: .sequentiallyConsistent))
            lastBeatIndex = Int(beatPhase.rounded(.down)) - 1
            envelope = 0
            oscPhase = 0
            startPending = true
        }

        let running = runningFlag.load(ordering: .sequentiallyConsistent)

        if startPending && running {
            let startHost = startHostTimeBits.load(ordering: .sequentiallyConsistent)
            let bufferHost = timestamp.pointee.mHostTime
            if bufferHost != 0 && startHost > bufferHost {
                let delay = Double(startHost - bufferHost) * HostClock.secondsPerTick
                framesUntilStart = Int(delay * sampleRate)
            } else {
                framesUntilStart = 0
            }
            startPending = false
        }

        let tempo = Double(bitPattern: tempoBits.load(ordering: .relaxed))
        let beatsPerBar = max(1, beatsPerBarValue.load(ordering: .relaxed))
        let countInBeats = countInBeatsValue.load(ordering: .relaxed)
        let audible = audibleFlag.load(ordering: .relaxed)
        let suppressed = suppressClickFlag.load(ordering: .relaxed)
        let volume = Double(bitPattern: volumeBits.load(ordering: .relaxed))
        let beatIncrement = tempo / (60.0 * sampleRate)

        for frame in 0..<Int(frameCount) {
            if running {
                if framesUntilStart > 0 {
                    framesUntilStart -= 1
                } else {
                    let beatIndex = Int(beatPhase)
                    if beatIndex > lastBeatIndex {
                        lastBeatIndex = beatIndex
                        // Count-in always clicks; afterwards only when the
                        // metronome is on and not suppressed by recording.
                        if beatIndex < countInBeats || (audible && !suppressed) {
                            let isDownbeat = beatIndex % beatsPerBar == 0
                            oscFrequency = isDownbeat ? 1760 : 1175
                            envelope = 1
                            oscPhase = 0
                        }
                    }
                    beatPhase += beatIncrement
                }
            }

            var sample = 0.0
            if envelope > 0.0001 {
                sample = sin(oscPhase * 2.0 * .pi) * envelope * envelope * volume
                oscPhase += oscFrequency / sampleRate
                if oscPhase >= 1 { oscPhase -= 1 }
                envelope *= envelopeDecay
            }
            out[frame] = Float(sample)
        }

        if running {
            beatPhaseBits.store(beatPhase.bitPattern, ordering: .relaxed)
        }
        return noErr
    }
}
