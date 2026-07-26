import AVFoundation

/// Owns audio capture into session cells: arm-gated recording from stopped or
/// while rolling, count-in, fixed/free length, overdub vs. replace, and the
/// trim-to-bars that turns a take into a loop clip.
///
/// Split out of `TransportEngine`. The record-specific bookkeeping lives here;
/// the observed transport state it touches (`mode`, `recordingSlot`,
/// `playback`) stays on the engine, reached through an `unowned` back-reference
/// so SwiftUI keeps observing it.
@MainActor
final class RecordingController {
    unowned let engine: TransportEngine

    init(engine: TransportEngine) { self.engine = engine }

    private var beat0Host: UInt64 = 0
    private var recordTempo: Double = 120
    private var recordStartBeat = 0.0
    private var recordAutoStopTask: Task<Void, Never>?
    /// When recording an overdub, the existing clip being layered onto; its
    /// length also fixes the take length via `recordBarsOverride`.
    private var overdubSource: Clip?
    private var recordBarsOverride: Int?
    /// A Replace-mode take that must clear its slot once recording begins.
    private var replaceClearPending = false

    /// Recording is only possible when the currently selected track is armed.
    var canRecord: Bool {
        engine.recordingSlot == nil && (engine.selectedTrack?.isArmed ?? false)
    }

    /// Beats captured so far in the take (negative during the count-in).
    var recordedBeats: Double { engine.currentBeats - recordStartBeat }

    /// The take's fixed length in beats, or nil when recording freely. Overdub
    /// is always fixed to the source clip's length.
    var fixedLengthBeats: Double? {
        guard let bars = recordBarsOverride ?? engine.recordLengthBars else { return nil }
        return Double(bars * engine.beatsPerBar)
    }

    /// R key / record button: record into the selected track. Only available
    /// when the selected track is armed. Targets the selected cell on that
    /// track, or its first empty slot if no cell on it is selected.
    func record() {
        guard engine.recordingSlot == nil else { return }
        guard let track = engine.selectedTrack, track.isArmed else {
            engine.statusMessage = "Arm the selected track (● in its header) to record."
            return
        }
        let scene: Int
        if let slot = engine.selectedSlot, slot.trackID == track.id, slot.scene < track.slots.count {
            scene = slot.scene
        } else if let firstEmpty = track.slots.firstIndex(where: { $0 == nil }) {
            scene = firstEmpty
        } else {
            engine.statusMessage = "No empty slot on \(track.name) — select a clip to overwrite or overdub."
            return
        }
        recordIntoSlot(track, scene: scene)
    }

    /// Records into a cell. Empty → new clip. Occupied → overdub (layer) or
    /// replace, per the track's `isOverdub` setting.
    func recordIntoSlot(_ track: Track, scene: Int) {
        engine.selectTrack(track)
        engine.selectedSlot = SlotRef(trackID: track.id, scene: scene)
        guard track.isArmed else {
            engine.statusMessage = "Arm the track first (● in its header)."
            return
        }
        guard engine.recordingSlot == nil else { return }

        let existing = track.slots[scene]
        if let existing, track.isOverdub {
            overdubSource = existing
            recordBarsOverride = existing.loopBars
        } else {
            overdubSource = nil
            recordBarsOverride = nil
            // Replacing an occupied slot: silence the outgoing clip now, and
            // clear it from the slot when recording actually begins.
            if existing != nil {
                stopTrackPlayback(track)
                replaceClearPending = true
            }
        }

        if engine.mode == .stopped {
            Task { await startRecordingFromStopped(track, scene: scene) }
        } else {
            startRecordingWhileRolling(track, scene: scene)
        }
    }

    private func stopTrackPlayback(_ track: Track) {
        guard let channel = engine.graph.channel(for: track.id) else { return }
        channel.pendingTask?.cancel()
        channel.pendingTask = nil
        channel.stopAllPlayers()
        engine.playback[track.id] = TrackPlayback()
    }

    /// Loops `clip` starting exactly at `host` for overdub monitoring, so the
    /// performer hears the existing take while recording the new layer.
    private func startMonitorPlayback(_ clip: Clip, on track: Track, atHost host: UInt64) {
        guard let channel = engine.graph.channel(for: track.id) else { return }
        let index = channel.activeIndex
        let player = channel.players[index]
        player.stop()
        player.scheduleBuffer(clip.buffer, at: nil, options: [.loops])
        player.play(at: AVAudioTime(hostTime: host))
    }

    /// Clicking the recording cell: finish the take and relaunch it, with the
    /// transport still rolling — the session-view jam loop.
    func finishRecordingAndPlay() {
        guard let slot = engine.recordingSlot else { return }
        recordAutoStopTask?.cancel()
        recordAutoStopTask = nil
        engine.metronome.setClickSuppressed(false)
        let clip = captureRecordedClip()
        engine.recordingSlot = nil
        engine.recordQueuedUntilBeat = nil
        engine.mode = .playing
        if let clip, let track = engine.tracks.first(where: { $0.id == slot.trackID }) {
            engine.launcher.launch(clip: clip, on: track)
        }
    }

    /// Fixed-length recording reached its end bar: capture the take and keep it
    /// sounding without a gap, phase-aligned to the boundary it ended on.
    private func autoFinishRecording(loopStartBeat: Double) {
        guard let slot = engine.recordingSlot else { return }
        engine.metronome.setClickSuppressed(false)
        let clip = captureRecordedClip()
        engine.recordingSlot = nil
        engine.recordQueuedUntilBeat = nil
        engine.mode = .playing
        guard let clip, let track = engine.tracks.first(where: { $0.id == slot.trackID }) else { return }
        engine.launcher.launchInProgress(clip: clip, on: track, loopStartBeat: loopStartBeat)
    }

    private func scheduleRecordAutoStop() {
        recordAutoStopTask?.cancel()
        recordAutoStopTask = nil
        // Overdub always runs for the source clip's length; otherwise the
        // REC BARS setting (nil = free, no auto-stop).
        guard let bars = recordBarsOverride ?? engine.recordLengthBars else { return }
        let endBeat = recordStartBeat + Double(bars * engine.beatsPerBar)
        recordAutoStopTask = Task { [weak self] in
            guard let self else { return }
            // Wake just past the boundary so the floor-to-bars trim lands
            // exactly on `bars`.
            await self.engine.sleep(untilBeat: endBeat + 0.02 * self.engine.tempo / 60)
            guard !Task.isCancelled, self.engine.recordingSlot != nil else { return }
            self.autoFinishRecording(loopStartBeat: endBeat)
        }
    }

    private func startRecordingFromStopped(_ track: Track, scene: Int) async {
        guard engine.mode == .stopped, engine.recordingSlot == nil else { return }

        if !engine.input.isConfigured {
            let outcome = await engine.input.configure()
            engine.applyConfigureOutcome(outcome, thenArm: nil)
            guard engine.input.isConfigured else { return }
        }
        engine.ensureEngineRunning()
        engine.recorder.beginCapture()

        engine.engineError = nil
        engine.statusMessage = nil
        recordTempo = engine.tempo
        recordStartBeat = 0
        engine.activeCountInBeats = engine.countInBars * engine.beatsPerBar

        let anchor = HostClock.now + HostClock.ticks(forSeconds: 0.1)
        let countInSeconds = Double(engine.activeCountInBeats) * 60.0 / recordTempo
        beat0Host = anchor + HostClock.ticks(forSeconds: countInSeconds)
        engine.metronome.start(countInBeats: engine.activeCountInBeats, atHostTime: anchor)
        if let source = overdubSource {
            startMonitorPlayback(source, on: track, atHost: beat0Host)
        }
        engine.recordingSlot = SlotRef(trackID: track.id, scene: scene)
        engine.mode = .recording
        engine.metronome.setClickSuppressed(true)
        scheduleRecordAutoStop()
        scheduleReplaceClear(atBeat: recordStartBeat)
    }

    private func startRecordingWhileRolling(_ track: Track, scene: Int) {
        guard engine.input.isConfigured else {
            engine.statusMessage = "Stop the transport and re-arm the track to set up the input first."
            return
        }
        engine.recorder.beginCapture()
        engine.statusMessage = nil
        recordTempo = engine.tempo

        // Punch in at the next bar regardless of the launch quantise setting.
        let beatsPerBar = Double(engine.beatsPerBar)
        let boundary = beatsPerBar * ((engine.currentBeats + 0.05 * engine.tempo / 60) / beatsPerBar).rounded(.up)
        recordStartBeat = boundary
        beat0Host = engine.hostTime(forBeat: boundary)
        if let source = overdubSource {
            startMonitorPlayback(source, on: track, atHost: beat0Host)
        }
        engine.recordingSlot = SlotRef(trackID: track.id, scene: scene)
        engine.recordQueuedUntilBeat = boundary
        engine.mode = .recording
        engine.metronome.setClickSuppressed(true)
        scheduleRecordAutoStop()
        scheduleReplaceClear(atBeat: boundary)

        Task { [weak engine] in
            await engine?.sleep(untilBeat: boundary)
            guard let engine else { return }
            if engine.recordQueuedUntilBeat == boundary { engine.recordQueuedUntilBeat = nil }
        }
    }

    /// Clears a Replace-mode target clip from its slot the moment recording
    /// actually starts (after count-in / at punch-in), so it isn't left sitting
    /// there during the take. Cancelling during count-in keeps it.
    private func scheduleReplaceClear(atBeat beat: Double) {
        guard replaceClearPending, let slot = engine.recordingSlot else { return }
        replaceClearPending = false
        Task { [weak engine] in
            await engine?.sleep(untilBeat: beat)
            guard let engine, engine.recordingSlot == slot,
                  let track = engine.tracks.first(where: { $0.id == slot.trackID }),
                  slot.scene < track.slots.count else { return }
            track.slots[slot.scene] = nil
        }
    }

    /// Trims the capture to whole bars from beat zero and drops it into the
    /// recording slot. Returns the new clip, or nil if the take was too short.
    @discardableResult
    func captureRecordedClip() -> Clip? {
        guard let slot = engine.recordingSlot else { return nil }
        engine.recorder.endCapture()

        let source = overdubSource
        overdubSource = nil
        let barsOverride = recordBarsOverride
        recordBarsOverride = nil

        // Anything captured past the count-in becomes a clip. Overdub and
        // fixed-length both yield an exact bar count (silence-padded if the
        // take was cut short); free mode rounds up to whole bars.
        let beatsRecorded = engine.currentBeats - recordStartBeat
        let bars = BeatMath.recordedBars(beatsRecorded: beatsRecorded,
                                         beatsPerBar: engine.beatsPerBar,
                                         fixed: barsOverride ?? engine.recordLengthBars)
        guard beatsRecorded > 0.05,
              let format = engine.recorder.captureFormat,
              let track = engine.tracks.first(where: { $0.id == slot.trackID }) else {
            engine.recorder.discard()
            engine.statusMessage = "Recording stopped during the count-in — discarded."
            return nil
        }

        let framesPerBeat = 60.0 / recordTempo * format.sampleRate
        let frameCount = AVAudioFrameCount((Double(bars * engine.beatsPerBar) * framesPerBeat).rounded())
        guard let captured = engine.recorder.makeLoopBuffer(beat0Host: beat0Host, frameCount: frameCount),
              let takeBuffer = AudioUtil.convert(captured, to: engine.standardFormat) else {
            engine.statusMessage = "Recording failed — no audio was captured."
            return nil
        }

        // Overdub: sum the new take onto the existing clip (same length).
        let buffer: AVAudioPCMBuffer
        let name: String
        let colorIndex: Int
        let loopBars: Int
        if let source, let mixed = AudioUtil.mix(base: source.buffer, overlay: takeBuffer) {
            buffer = mixed
            name = source.name
            colorIndex = source.colorIndex
            loopBars = source.loopBars
            engine.statusMessage = "Overdubbed \(source.name)."
        } else {
            buffer = takeBuffer
            name = "\(track.name) \(slot.scene + 1)"
            colorIndex = track.colorIndex
            loopBars = bars
            engine.statusMessage = nil
        }

        let url = engine.recorder.writeFile(buffer: buffer, name: name)
        // The take (and any overdub layered onto it) spans `loopBars` bars at
        // the tempo it was recorded at — that's the clip's native tempo.
        let clip = Clip(name: name, colorIndex: colorIndex, buffer: buffer,
                        loopBars: loopBars, fileURL: url, nativeTempo: recordTempo)
        clip.applyTempo(engine.tempo)
        track.slots[slot.scene] = clip
        engine.markDirty()
        return clip
    }

    /// Global stop reached us: finish any in-progress take, clear the recording
    /// state, and re-enable the click. Called by `TransportEngine.stop()`.
    func handleTransportStop() {
        recordAutoStopTask?.cancel()
        recordAutoStopTask = nil
        engine.metronome.setClickSuppressed(false)
        if engine.recordingSlot != nil {
            captureRecordedClip()
            engine.recordingSlot = nil
            engine.recordQueuedUntilBeat = nil
        }
        overdubSource = nil
        recordBarsOverride = nil
        replaceClearPending = false
    }
}
