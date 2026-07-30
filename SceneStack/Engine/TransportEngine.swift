import AVFoundation
import AudioToolbox
import Observation

/// Owns the AVAudioEngine graph, the session model, and the transport state
/// machine.
///
/// The metronome's render clock is the single source of timing truth; the UI
/// polls `currentBeats` from a `TimelineView` rather than observing it.
/// Transport starts are anchored to a host time slightly in the future, and
/// quantised clip launches/stops are scheduled against that same clock:
/// launches sample-accurately via `AVAudioPlayerNode.play(at:)`, boundary
/// bookkeeping (stopping the outgoing player, UI state) via async tasks.
@MainActor
@Observable
final class TransportEngine {

    enum Mode: Equatable {
        case stopped
        case playing
        case recording
    }

    // The following four are settable within the module (not `private(set)`) so
    // `ClipLauncher` / `RecordingController` can drive them; the UI only reads
    // them. `@Observable` still tracks them regardless of setter access.
    var mode: Mode = .stopped
    private(set) var tracks: [Track] = []
    /// Scene rows, in top-to-bottom order. Each carries only a stable id; the
    /// clips themselves live positionally in each track's `slots` array, keyed
    /// by row index. Kept exactly in lockstep with every track's slot count.
    private(set) var scenes: [SessionScene] = (0..<4).map { _ in SessionScene() }
    /// Number of scene rows — derived from `scenes`, the single source of truth.
    var sceneCount: Int { scenes.count }
    /// Track whose device chain is shown in the FX bar.
    var selectedTrackID: UUID?

    var selectedTrack: Track? {
        tracks.first { $0.id == selectedTrackID } ?? tracks.first
    }

    /// Per-track playing/queued state for the grid UI.
    var playback: [UUID: TrackPlayback] = [:]
    /// The slot currently being recorded into, if any.
    var recordingSlot: SlotRef?
    /// Non-nil while a rolling-transport recording waits for its bar boundary.
    var recordQueuedUntilBeat: Double?
    /// Last-clicked clip slot; DEL deletes it.
    var selectedSlot: SlotRef?
    /// Last-clicked scene row, outlined in the grid.
    var selectedScene: Int?
    /// Fixed record length in bars; nil (the default) records freely until
    /// stopped.
    var recordLengthBars: Int?

    var quantize: LaunchQuantize = .bar {
        didSet { markDirty() }
    }
    var engineError: String?
    /// Transient, non-fatal feedback ("clip too short", device unplugged…).
    var statusMessage: String?
    /// Where ⌘S saves without asking; set by the save/open panels.
    var projectURL: URL?
    /// True once the project has edits not yet written to disk. Drives the
    /// "save changes?" prompt on New Project.
    private(set) var hasUnsavedChanges = false
    /// Set while loading/resetting so bulk model changes don't mark dirty.
    @ObservationIgnored private var suppressDirty = false

    func markDirty() {
        if !suppressDirty { hasUnsavedChanges = true }
    }

    func markSaved() {
        hasUnsavedChanges = false
    }

    /// Undo/redo for clip edits (⌘Z / ⇧⌘Z).
    @ObservationIgnored let undoManager = UndoManager()

    /// Core Audio input devices; owned by the input controller and exposed
    /// for the input picker UI.
    var devices: DeviceManager { input.devices }

    var tempo: Double = 120 {
        didSet {
            let clamped = min(max(tempo.rounded(), 20), 300)
            if clamped != tempo { tempo = clamped; return }
            guard tempo != oldValue else { return }
            metronome.setTempo(tempo)   // clock/metronome follow instantly
            scheduleWarp()              // the costly clip re-warp is debounced
            markDirty()
        }
    }

    /// Pitch-preserving clip warping is a per-clip offline render, far too heavy
    /// to run on every step of a tempo drag. The metronome tracks tempo live;
    /// the warp waits for the tempo to settle. Until it fires, playing loops
    /// briefly drift, then snap back into phase when the re-warp reschedules them.
    @ObservationIgnored private var warpDebounce: Task<Void, Never>?

    private func scheduleWarp() {
        warpDebounce?.cancel()
        warpDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.warpClipsToCurrentTempo()
        }
    }

    /// Re-warps every clip so its loop spans the right number of bars at the new
    /// tempo, and reschedules any playing loop with its freshly-warped buffer so
    /// it stays locked to the grid instead of drifting.
    ///
    /// Each render happens off the main actor and is awaited one clip at a time,
    /// so a large session re-warps without the UI ever going unresponsive.
    /// Clips that are currently sounding go first and are re-aligned the moment
    /// their own buffer is ready, rather than waiting for the whole session.
    private func warpClipsToCurrentTempo() async {
        let target = tempo
        let playingIDs = Set(playback.values.compactMap(\.playingClipID))
        let clips = allClips()
        let sounding = clips.filter { playingIDs.contains($0.id) }
        let rest = clips.filter { !playingIDs.contains($0.id) }

        for clip in sounding + rest {
            await clip.warp(to: target)
            // A newer tempo landed while this was rendering: that edit schedules
            // its own warp, and finishing this one would fight it.
            guard !Task.isCancelled, tempo == target else { return }
            if mode != .stopped, playingIDs.contains(clip.id) {
                realignPlayingLoop(clip)
            }
        }
    }

    /// Restarts whichever track is looping `clip`, in phase, on its newly
    /// warped buffer.
    private func realignPlayingLoop(_ clip: Clip) {
        for track in tracks {
            guard let state = playback[track.id], state.playingClipID == clip.id else { continue }
            launcher.launchInProgress(clip: clip, on: track, loopStartBeat: state.playingStartBeat)
        }
    }

    var beatsPerBar = 4 {
        didSet {
            metronome.setBeatsPerBar(beatsPerBar)
            markDirty()
        }
    }

    /// Count-in length in bars, applied when recording starts from stopped.
    var countInBars = 2 {
        didSet { markDirty() }
    }

    var metronomeEnabled = true {
        didSet {
            metronome.setClickAudible(metronomeEnabled)
            UserDefaults.standard.set(metronomeEnabled, forKey: Prefs.metronomeEnabled)
        }
    }

    var metronomeVolume = 0.7 {
        didSet {
            metronome.setVolume(metronomeVolume)
            UserDefaults.standard.set(metronomeVolume, forKey: Prefs.metronomeVolume)
        }
    }

    /// Input gain applied to recorded audio (and the input meter). 1 = unity.
    var inputGain = 1.0 {
        didSet {
            recorder.setInputGain(inputGain)
            graph.setMonitorGain(inputGain)
            UserDefaults.standard.set(inputGain, forKey: Prefs.inputGain)
        }
    }

    /// Hear live input through the armed track's effects and fader while you
    /// play. Off by default and deliberately opt-in: on a machine using
    /// speakers rather than headphones, monitoring an open mic feeds back.
    var monitorInput = false {
        didSet {
            UserDefaults.standard.set(monitorInput, forKey: Prefs.monitorInput)
            guard monitorInput != oldValue else { return }
            applyMonitoring()
        }
    }

    /// Toggles monitoring from the UI, explaining the no-op case. Separate from
    /// the property so restoring the preference at launch doesn't post a status
    /// message about a state the user hasn't just chosen.
    func toggleMonitoring() {
        monitorInput.toggle()
        if monitorInput, armedTrack == nil {
            statusMessage = "Monitoring is on — arm a track (●) to hear its input."
        }
    }

    /// Which track should receive live input. Pure so the rule is testable on
    /// its own: the armed track, but only once monitoring is on and the input
    /// is actually live.
    nonisolated static func monitorTarget(monitorEnabled: Bool, inputConfigured: Bool,
                                          armedTrackID: UUID?) -> UUID? {
        guard monitorEnabled, inputConfigured else { return nil }
        return armedTrackID
    }

    /// Re-applies the monitoring route after anything that could change it:
    /// the toggle, which track is armed, input coming up or going away, or
    /// that track being deleted.
    func applyMonitoring() {
        let target = Self.monitorTarget(monitorEnabled: monitorInput,
                                        inputConfigured: input.isConfigured,
                                        armedTrackID: armedTrack?.id)
        Task { await graph.setMonitoring(to: target, gain: inputGain) }
    }

    /// Preference keys for setup-level settings that persist across launches.
    private enum Prefs {
        static let metronomeEnabled = "metronomeEnabled"
        static let metronomeVolume = "metronomeVolume"
        static let inputGain = "inputGain"
        static let monitorInput = "monitorInput"
    }

    /// Restores setup preferences; each assignment re-applies via its didSet.
    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Prefs.metronomeEnabled) != nil {
            metronomeEnabled = defaults.bool(forKey: Prefs.metronomeEnabled)
        }
        if defaults.object(forKey: Prefs.metronomeVolume) != nil {
            metronomeVolume = defaults.double(forKey: Prefs.metronomeVolume)
        }
        if defaults.object(forKey: Prefs.inputGain) != nil {
            inputGain = defaults.double(forKey: Prefs.inputGain)
        }
        if defaults.object(forKey: Prefs.monitorInput) != nil {
            monitorInput = defaults.bool(forKey: Prefs.monitorInput)
        }
    }

    var masterVolume = 0.9 {
        didSet {
            graph.setMasterVolume(masterVolume)
            markDirty()
        }
    }

    /// Total count-in beats of the transport run currently in progress. Set by
    /// `RecordingController`, read by the transport bar's beat readout.
    @ObservationIgnored var activeCountInBeats = 0

    /// The AVAudioEngine node graph (channels, mixing, effects, lifecycle).
    /// `internal` (not `private`) so the extracted `ClipLauncher` /
    /// `RecordingController` can reach the shared audio nodes.
    @ObservationIgnored let graph = AudioGraph()
    @ObservationIgnored let metronome: MetronomeSource
    @ObservationIgnored let recorder = RecordingService()
    @ObservationIgnored let input: AudioInputController

    /// Clip launch/stop scheduling, and audio capture into cells — split out of
    /// this god-object into focused controllers that drive the engine's
    /// observed state through an `unowned` back-reference.
    @ObservationIgnored private(set) lazy var launcher = ClipLauncher(engine: self)
    @ObservationIgnored private(set) lazy var recording = RecordingController(engine: self)

    /// Standard clip format — the graph normalises every buffer to it.
    var standardFormat: AVAudioFormat { graph.standardFormat }
    /// Master output meter, polled by the mixer UI.
    var masterMeter: MeterTap { graph.masterMeter }

    /// Beats since bar 1 started; negative while counting in. Poll, don't observe.
    var currentBeats: Double { metronome.currentBeats }

    var isCountingIn: Bool { mode == .recording && currentBeats < 0 }

    /// Smoothed input level (0...1) while capturing. Poll, don't observe.
    var inputPeak: Double { recorder.inputPeak }

    var armedTrack: Track? { tracks.first { $0.isArmed } }

    init() {
        metronome = MetronomeSource(sampleRate: graph.sampleRate)
        input = AudioInputController(graph: graph, recorder: recorder)

        graph.attachSource(metronome.node)
        graph.setMasterVolume(masterVolume)
        startEngine()
        graph.installMasterMeter()

        for index in 0..<4 { addTrack(named: "Track \(index + 1)") }
        selectedTrackID = tracks.first?.id
        if sceneCount > 0 { selectedScene = 0 }

        devices.onDeviceListChanged = { [weak self] in
            self?.handleDeviceListChange()
        }

        graph.onConfigurationChange = { [weak self] in
            self?.handleAudioConfigurationChange()
        }

        loadPreferences()

        // Every launch starts on a blank project — no previous project is
        // reopened. Use File › Open to return to saved work, or Load Demo Set
        // for the demo content.
        undoManager.removeAllActions()
        hasUnsavedChanges = false

        // Autosave every two minutes once the project has a home, while idle and
        // only when there is something new to write. A failure here matters —
        // the user believes their work is being saved — so it surfaces rather
        // than being swallowed.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard let self else { return }
                guard let url = self.projectURL, self.mode == .stopped,
                      self.hasUnsavedChanges else { continue }
                do {
                    try ProjectStore.write(engine: self, to: url)
                } catch {
                    self.engineError = "Autosave failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Saving

    func saveInPlace() {
        guard let url = projectURL else {
            ProjectStore.saveWithPanel(engine: self)
            return
        }
        do {
            try ProjectStore.write(engine: self, to: url)
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            engineError = "Couldn't save project: \(error.localizedDescription)"
        }
    }

    // MARK: - Undo

    private func registerUndo(_ actionName: String,
                              _ handler: @escaping (TransportEngine) -> Void) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { handler(target) }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Session structure

    func addTrack(named name: String? = nil) {
        let track = Track(name: name ?? "Track \(tracks.count + 1)",
                          colorIndex: tracks.count % 6,
                          sceneCount: sceneCount)
        graph.addChannel(for: track.id)
        tracks.append(track)
        applyMix(track)
        markDirty()
        registerUndo("Add Track") { $0.deleteTrack(track) }
    }

    func deleteTrack(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        if recordingSlot?.trackID == track.id { stop() }
        let savedEffects = track.effects
        for effect in track.effects {
            PluginWindows.close(effect.id)
            graph.detachEffect(effect.node)
        }
        track.effects.removeAll()
        graph.removeChannel(for: track.id)
        playback.removeValue(forKey: track.id)
        tracks.removeAll { $0.id == track.id }
        if selectedTrackID == track.id { selectedTrackID = tracks.first?.id }
        if selectedSlot?.trackID == track.id { selectedSlot = nil }
        applyMixAll()
        applyMonitoring()   // the monitored track may have been the deleted one
        markDirty()
        registerUndo("Delete Track") { $0.restoreTrack(track, at: index, effects: savedEffects) }
    }

    /// Undo of `deleteTrack`: re-create the channel, re-attach the same
    /// effect nodes and rewire the chain, and re-insert the track.
    private func restoreTrack(_ track: Track, at index: Int, effects: [EffectInstance]) {
        graph.addChannel(for: track.id)
        track.effects = effects
        for effect in effects { graph.attachEffect(effect.node) }
        graph.rebuildChain(for: track.id, effects: track.effects)
        tracks.insert(track, at: min(index, tracks.count))
        applyMix(track)
        selectTrack(track)
        markDirty()
        registerUndo("Delete Track") { $0.deleteTrack(track) }
    }

    /// Reorders a track column (drag left/right). Everything else is keyed by
    /// track id — the audio channels, playback state and selection — so only
    /// the array order changes; no audio is interrupted.
    func moveTrack(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < tracks.count,
              destination >= 0, destination < tracks.count else { return }
        let moved = tracks.remove(at: source)
        tracks.insert(moved, at: destination)
        markDirty()
        registerUndo("Move Track") { $0.moveTrack(from: destination, to: source) }
    }

    /// Resolves a dragged-track payload onto the column it was dropped on.
    func handleTrackDropPayload(_ payload: String, onto destinationID: UUID) {
        let prefix = "trackmove:"
        guard payload.hasPrefix(prefix),
              let sourceID = UUID(uuidString: String(payload.dropFirst(prefix.count))),
              let source = tracks.firstIndex(where: { $0.id == sourceID }),
              let destination = tracks.firstIndex(where: { $0.id == destinationID })
        else { return }
        moveTrack(from: source, to: destination)
    }

    func addScene() {
        scenes.append(SessionScene())
        for track in tracks { track.slots.append(nil) }
        markDirty()
    }

    /// Inserts an empty scene row at `index`, shifting later rows (and any
    /// anchored selection/recording) down. Does not mark dirty — the caller
    /// does, as part of a larger edit.
    func insertScene(at index: Int) {
        let clamped = max(0, min(index, sceneCount))
        for track in tracks { track.slots.insert(nil, at: clamped) }
        scenes.insert(SessionScene(), at: clamped)
        if let scene = selectedScene, scene >= clamped { selectedScene = scene + 1 }
        if let slot = selectedSlot, slot.scene >= clamped {
            selectedSlot = SlotRef(trackID: slot.trackID, scene: slot.scene + 1)
        }
        if let slot = recordingSlot, slot.scene >= clamped {
            recordingSlot = SlotRef(trackID: slot.trackID, scene: slot.scene + 1)
        }
    }

    /// Reorders a scene row (drag up/down). Every track's slots are permuted
    /// identically; numbering stays consecutive since it's just row index + 1.
    func moveScene(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < sceneCount,
              destination >= 0, destination < sceneCount else { return }
        for track in tracks {
            let moved = track.slots.remove(at: source)
            track.slots.insert(moved, at: destination)
        }
        let movedScene = scenes.remove(at: source)
        scenes.insert(movedScene, at: destination)
        selectedScene = remapSceneIndex(selectedScene, from: source, to: destination)
        if let slot = selectedSlot {
            selectedSlot = SlotRef(trackID: slot.trackID,
                                   scene: remapSceneIndex(slot.scene, from: source, to: destination) ?? slot.scene)
        }
        if let slot = recordingSlot {
            recordingSlot = SlotRef(trackID: slot.trackID,
                                    scene: remapSceneIndex(slot.scene, from: source, to: destination) ?? slot.scene)
        }
        markDirty()
        registerUndo("Move Scene") { $0.moveScene(from: destination, to: source) }
    }

    /// Where a row index ends up after moving `source` to `destination`.
    private func remapSceneIndex(_ index: Int?, from source: Int, to destination: Int) -> Int? {
        guard let index else { return nil }
        return BeatMath.sceneIndexAfterMove(index, from: source, to: destination)
    }

    /// Whether a scene row holds at least one clip (drives the enabled state
    /// of "Duplicate Scene").
    func sceneHasClips(_ scene: Int) -> Bool {
        guard scene >= 0, scene < sceneCount else { return false }
        return tracks.contains { scene < $0.slots.count && $0.slots[scene] != nil }
    }

    /// Whether any clip currently sounding lives in this scene row — i.e. the
    /// row is actually playing. Drives the launch-button pulse, so it tracks the
    /// audio rather than the selection (duplicating a scene mustn't move the
    /// "playing" indicator off the row whose clips are still looping).
    func sceneIsPlaying(_ scene: Int) -> Bool {
        guard mode != .stopped, scene >= 0, scene < sceneCount else { return false }
        return tracks.contains { track in
            guard let playingID = playback[track.id]?.playingClipID,
                  scene < track.slots.count else { return false }
            return track.slots[scene]?.id == playingID
        }
    }

    /// Right-click a scene number: duplicate the whole row (all its clips)
    /// into a new scene inserted directly below.
    func duplicateScene(_ scene: Int) {
        guard scene >= 0, scene < sceneCount else { return }
        let targetScene = scene + 1
        insertScene(at: targetScene)
        for track in tracks {
            if let clip = track.slots[scene] {
                track.slots[targetScene] = duplicate(of: clip)
            }
        }
        markDirty()
        selectedScene = targetScene
        registerUndo("Duplicate Scene") { engine in
            engine.removeScene(at: targetScene)
            engine.markDirty()
            engine.registerUndo("Duplicate Scene") { $0.duplicateScene(scene) }
        }
    }

    /// Right-click a scene number: delete the whole row (undoable). The grid
    /// can be emptied entirely; add rows again with the + button.
    func deleteScene(_ scene: Int) {
        guard scene >= 0, scene < sceneCount else { return }
        let saved: [(trackID: UUID, clip: Clip)] = tracks.compactMap { track in
            track.slots[scene].map { (track.id, $0) }
        }
        removeScene(at: scene)
        markDirty()
        registerUndo("Delete Scene") { engine in
            engine.insertScene(at: scene)
            for entry in saved {
                if let track = engine.tracks.first(where: { $0.id == entry.trackID }),
                   scene < track.slots.count {
                    track.slots[scene] = entry.clip
                }
            }
            engine.markDirty()
            engine.registerUndo("Delete Scene") { $0.deleteScene(scene) }
        }
    }

    /// Removes the scene row at `index`, stopping any clip playing in it and
    /// shifting later rows up.
    func removeScene(at index: Int) {
        guard index >= 0, index < sceneCount else { return }
        for track in tracks {
            if let clip = track.slots[index],
               let state = playback[track.id],
               state.playingClipID == clip.id || state.queuedClipID == clip.id,
               let channel = graph.channel(for: track.id) {
                channel.pendingTask?.cancel()
                channel.stopAllPlayers()
                playback[track.id] = TrackPlayback()
            }
            track.slots.remove(at: index)
        }
        scenes.remove(at: index)
        if let scene = selectedScene {
            if scene > index { selectedScene = scene - 1 }
            else if scene == index { selectedScene = sceneCount > 0 ? min(index, sceneCount - 1) : nil }
        }
        if let slot = selectedSlot {
            if slot.scene == index { selectedSlot = nil }
            else if slot.scene > index {
                selectedSlot = SlotRef(trackID: slot.trackID, scene: slot.scene - 1)
            }
        }
    }

    /// Selecting a track drops any clip selection on other tracks, so DEL
    /// always targets what the eye is on.
    func selectTrack(_ track: Track) {
        selectedTrackID = track.id
        if let slot = selectedSlot, slot.trackID != track.id {
            selectedSlot = nil
        }
    }

    /// Rename a track (undoable). Blank names are rejected — a track keeps its
    /// current name if the new one is empty or only whitespace.
    func renameTrack(_ track: Track, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != track.name else { return }
        let previous = track.name
        track.name = trimmed
        markDirty()
        registerUndo("Rename Track") { $0.renameTrack(track, to: previous) }
    }

    func selectScene(_ scene: Int) {
        guard scene >= 0, scene < sceneCount else { return }
        selectedScene = scene
    }

    // MARK: - Mixing

    /// Continuous — applied live during a slider/knob drag; undo is registered
    /// once per gesture via `commitVolume`/`commitPan`.
    func setVolume(_ track: Track, _ volume: Double) {
        selectTrack(track)
        track.volume = volume
        applyMix(track)
        markDirty()
    }

    func setPan(_ track: Track, _ pan: Double) {
        selectTrack(track)
        track.pan = pan
        applyMix(track)
        markDirty()
    }

    /// Registers a single undo for a completed volume drag (from `previous`
    /// to the current value).
    func commitVolume(_ track: Track, from previous: Double) {
        let current = track.volume
        guard previous != current else { return }
        registerUndo("Track Volume") { $0.applyVolume(track, to: previous, undoTo: current) }
    }

    func commitPan(_ track: Track, from previous: Double) {
        let current = track.pan
        guard previous != current else { return }
        registerUndo("Track Pan") { $0.applyPan(track, to: previous, undoTo: current) }
    }

    private func applyVolume(_ track: Track, to value: Double, undoTo other: Double) {
        track.volume = value
        applyMix(track)
        markDirty()
        registerUndo("Track Volume") { $0.applyVolume(track, to: other, undoTo: value) }
    }

    private func applyPan(_ track: Track, to value: Double, undoTo other: Double) {
        track.pan = value
        applyMix(track)
        markDirty()
        registerUndo("Track Pan") { $0.applyPan(track, to: other, undoTo: value) }
    }

    func commitMasterVolume(from previous: Double) {
        let current = masterVolume
        guard previous != current else { return }
        registerUndo("Master Volume") { $0.applyMasterVolume(to: previous, undoTo: current) }
    }

    private func applyMasterVolume(to value: Double, undoTo other: Double) {
        masterVolume = value  // didSet applies to the graph and marks dirty
        registerUndo("Master Volume") { $0.applyMasterVolume(to: other, undoTo: value) }
    }

    func toggleMute(_ track: Track) {
        selectTrack(track)
        track.isMuted.toggle()
        applyMixAll()
        markDirty()
        registerUndo("Mute Track") { $0.toggleMute(track) }
    }

    /// Exclusive solo: soloing a track silences every other track, so only
    /// this one plays. Clicking an already-soloed track clears solo.
    func toggleSolo(_ track: Track) {
        selectTrack(track)
        let previous = tracks.map { ($0.id, $0.isSoloed) }
        let willSolo = !track.isSoloed
        for other in tracks { other.isSoloed = false }
        track.isSoloed = willSolo
        applyMixAll()
        markDirty()
        registerUndo("Solo Track") { $0.restoreSolo(previous) }
    }

    private func restoreSolo(_ state: [(UUID, Bool)]) {
        let current = tracks.map { ($0.id, $0.isSoloed) }
        for (id, soloed) in state { tracks.first { $0.id == id }?.isSoloed = soloed }
        applyMixAll()
        markDirty()
        registerUndo("Solo Track") { $0.restoreSolo(current) }
    }

    /// Record-into-occupied-clip mode: overdub (layer) when on, replace when off.
    func toggleOverdub(_ track: Track) {
        selectTrack(track)
        track.isOverdub.toggle()
        markDirty()
        registerUndo("Record Mode") { $0.toggleOverdub(track) }
    }

    func meterLevels(for track: Track) -> (left: Double, right: Double) {
        graph.meterLevels(for: track.id)
    }

    private func applyMixAll() {
        for track in tracks { applyMix(track) }
    }

    private func applyMix(_ track: Track) {
        let anySolo = tracks.contains { $0.isSoloed }
        let audible = !track.isMuted && (!anySolo || track.isSoloed)
        graph.setMix(for: track.id, volume: track.volume, pan: track.pan, audible: audible)
    }

    // MARK: - AU effects

    /// Installed AU effects (`aufx`), sorted by manufacturer then name.
    func effectComponents() -> [AVAudioUnitComponent] {
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_Effect
        return AVAudioUnitComponentManager.shared().components(matching: description)
            .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }

    func addEffect(_ component: AVAudioUnitComponent, to track: Track) {
        let description = component.audioComponentDescription
        let name = component.name
        let manufacturer = component.manufacturerName
        Task {
            do {
                let unit = try await AVAudioUnit.instantiate(with: description, options: [])
                graph.attachEffect(unit)
                let effect = EffectInstance(name: name, manufacturer: manufacturer,
                                            componentDescription: description, node: unit)
                track.effects.append(effect)
                await graph.rebuildChainFaded(for: track.id, effects: track.effects)
                markDirty()
                statusMessage = nil
            } catch {
                statusMessage = "Couldn't load \(name): \(error.localizedDescription)"
            }
        }
    }

    func removeEffect(_ effect: EffectInstance, from track: Track) {
        PluginWindows.close(effect.id)
        track.effects.removeAll { $0.id == effect.id }
        markDirty()
        // Fade the rebuild, then detach the now-orphaned node once it's out of
        // the chain.
        Task {
            await graph.rebuildChainFaded(for: track.id, effects: track.effects)
            graph.detachEffect(effect.node)
        }
    }

    /// Moves an effect one step left (-1) or right (+1) in the chain.
    func moveEffect(_ effect: EffectInstance, in track: Track, by offset: Int) {
        guard let index = track.effects.firstIndex(where: { $0.id == effect.id }) else { return }
        let target = index + offset
        guard target >= 0, target < track.effects.count else { return }
        track.effects.swapAt(index, target)
        markDirty()
        Task { await graph.rebuildChainFaded(for: track.id, effects: track.effects) }
    }

    /// Re-instantiates a saved effect and applies its archived state.
    func restoreEffect(name: String, manufacturer: String,
                       description: AudioComponentDescription,
                       state: Data?, bypassed: Bool, on track: Track) async {
        do {
            let unit = try await AVAudioUnit.instantiate(with: description, options: [])
            graph.attachEffect(unit)
            if let state,
               let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: state) {
                unarchiver.requiresSecureCoding = false
                if let fullState = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [String: Any] {
                    unit.auAudioUnit.fullState = fullState
                }
            }
            let effect = EffectInstance(name: name, manufacturer: manufacturer,
                                        componentDescription: description, node: unit)
            effect.isBypassed = bypassed
            track.effects.append(effect)
            graph.rebuildChain(for: track.id, effects: track.effects)
        } catch {
            statusMessage = "Couldn't restore effect \(name) — is the plugin still installed?"
        }
    }

    // MARK: - Arming & input

    func toggleArm(_ track: Track) {
        if track.isArmed {
            track.isArmed = false
            applyMonitoring()   // nothing armed — drop the monitor path
            return
        }
        guard mode != .recording else { return }
        if input.isConfigured {
            armOnly(track)
        } else {
            guard mode == .stopped else {
                statusMessage = "Stop the transport before arming for the first time."
                return
            }
            Task {
                let outcome = await input.configure()
                applyConfigureOutcome(outcome, thenArm: track)
            }
        }
    }

    /// One armed track at a time — there is one recording input. Selection
    /// follows the armed track so the FX bar and shortcuts focus with it.
    private func armOnly(_ track: Track) {
        for other in tracks { other.isArmed = (other.id == track.id) }
        selectTrack(track)
        applyMonitoring()   // monitoring follows the armed track
    }

    func selectInputDevice(_ id: AudioDeviceID) {
        guard devices.selectedDeviceID != id else { return }
        devices.selectedDeviceID = id
        guard input.isConfigured else { return }
        if mode == .stopped {
            Task {
                let outcome = await input.configure()
                applyConfigureOutcome(outcome, thenArm: nil)
            }
        } else {
            input.invalidate()
            statusMessage = "Input change applies once the transport stops — re-arm the track."
        }
    }

    /// Translates the input controller's bring-up outcome into UI state and
    /// arms the requested track on success.
    func applyConfigureOutcome(_ outcome: AudioInputController.ConfigureOutcome,
                                       thenArm track: Track?) {
        switch outcome {
        case .success:
            engineError = nil
            statusMessage = nil
            if let track { armOnly(track) }
            applyMonitoring()   // bring-up rewired the input; re-establish the route
        case .successUsingDefault:
            engineError = nil
            statusMessage = "Using the system default input device."
            if let track { armOnly(track) }
            applyMonitoring()
        case .permissionDenied:
            engineError = "Microphone access denied — enable it in System Settings › Privacy & Security › Microphone."
        case .failed(let message):
            // Bring the base (output-only) engine back, then surface the error.
            startEngine()
            engineError = message
        }
    }

    // MARK: - Transport

    /// Main Play launches the currently selected scene (or just starts the
    /// transport if no scene is selected); Play again stops.
    func togglePlayStop() {
        if mode == .stopped {
            if let scene = selectedScene {
                launchScene(scene)
            } else {
                play()
            }
        } else {
            stop()
        }
    }

    func play() {
        guard mode == .stopped else { return }
        startRolling()
    }

    /// Global stop: finish any recording, stop all clips and the clock.
    func stop() {
        recording.handleTransportStop()
        for channel in graph.channels.values {
            channel.pendingTask?.cancel()
            channel.pendingTask = nil
            channel.stopAllPlayers()
        }
        playback = [:]
        metronome.stop()
        mode = .stopped
    }

    /// Starts the clock rolling (no clips) and returns the beat-zero anchor.
    /// `internal` so `ClipLauncher` can start the transport for a launch.
    @discardableResult
    func startRolling() -> UInt64 {
        ensureEngineRunning()
        activeCountInBeats = 0
        let anchor = HostClock.now + HostClock.ticks(forSeconds: 0.1)
        metronome.start(countInBeats: 0, atHostTime: anchor)
        mode = .playing
        return anchor
    }

    // MARK: - Clip launching

    // Implementations live in `ClipLauncher`; these thin forwarders keep the
    // engine's public API (and every UI call site) unchanged.
    func launch(clip: Clip, on track: Track) { launcher.launch(clip: clip, on: track) }
    func stopClip(on track: Track) { launcher.stopClip(on: track) }
    func launchScene(_ scene: Int) { launcher.launchScene(scene) }
    func stopAllClips() { launcher.stopAllClips() }

    // MARK: - Performance keys

    /// Push-style keyboard launching. The number row (`1`–`9`, `0`) launches
    /// scenes 1–10; the home row (`A S D F G H J K L`) launches the *selected*
    /// scene's clip on tracks 1–9, stopping the track if that cell is empty;
    /// backtick (`` ` ``) stops every clip. Returns whether the key was a launch
    /// action (so the caller can swallow it), leaving anything else untouched.
    @discardableResult
    func performLaunchKey(_ character: Character) -> Bool {
        switch character {
        case "1"..."9":
            let scene = character.wholeNumberValue! - 1
            guard scene < sceneCount else { return false }
            launchScene(scene)
            return true
        case "0":
            guard sceneCount >= 10 else { return false }
            launchScene(9)
            return true
        case "`":
            stopAllClips()
            return true
        default:
            let homeRow = Array("asdfghjkl")
            guard let column = homeRow.firstIndex(of: Character(character.lowercased())) else { return false }
            return launchClipByKey(track: column)
        }
    }

    /// Launches (or stops) the clip in the selected scene on the given track
    /// column. Returns false when there's no such track or no selected scene.
    private func launchClipByKey(track column: Int) -> Bool {
        guard column < tracks.count, let scene = selectedScene, scene < sceneCount else { return false }
        let track = tracks[column]
        if let clip = track.slots[scene] {
            launch(clip: clip, on: track)
        } else {
            stopClip(on: track)
        }
        return true
    }

    // MARK: - Recording

    // Implementations live in `RecordingController`; these thin forwarders keep
    // the engine's public API (and every UI call site) unchanged.
    var canRecord: Bool { recording.canRecord }
    /// Live-waveform inputs for the cell being recorded into. Poll, don't observe.
    var recordedBeats: Double { recording.recordedBeats }
    var recordFixedLengthBeats: Double? { recording.fixedLengthBeats }
    func liveRecordingWaveform(bins: Int, lastSeconds: Double? = nil) -> [Float] {
        recorder.liveWaveform(bins: bins, lastSeconds: lastSeconds)
    }
    func record() { recording.record() }
    func recordIntoSlot(_ track: Track, scene: Int) { recording.recordIntoSlot(track, scene: scene) }
    func finishRecordingAndPlay() { recording.finishRecordingAndPlay() }

    // MARK: - Clip management

    /// Rename a clip (undoable).
    func renameClip(_ clip: Clip, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != clip.name else { return }
        let previous = clip.name
        clip.name = trimmed
        markDirty()
        registerUndo("Rename Clip") { $0.renameClip(clip, to: previous) }
    }

    /// Recolour a clip — routed through the engine so it marks the project
    /// dirty and registers undo, rather than the view mutating the model.
    func setClipColor(_ clip: Clip, colorIndex: Int) {
        guard clip.colorIndex != colorIndex else { return }
        let previous = clip.colorIndex
        clip.colorIndex = colorIndex
        markDirty()
        registerUndo("Recolour Clip") { $0.setClipColor(clip, colorIndex: previous) }
    }

    /// ⌘D / Track menu: duplicate the selected clip into the scene below.
    func duplicateSelectedClip() {
        guard let slot = selectedSlot,
              let track = tracks.first(where: { $0.id == slot.trackID }),
              slot.scene < track.slots.count, let clip = track.slots[slot.scene] else { return }
        duplicateClipDown(clip, on: track, scene: slot.scene)
    }

    /// Duplicates a clip into the scene below on the same track:
    /// - empty slot below → duplicate into it;
    /// - occupied slot below → insert a new scene there and duplicate into it;
    /// - no scene below → append a scene and duplicate into it.
    func duplicateClipDown(_ clip: Clip, on track: Track, scene: Int) {
        guard scene >= 0, scene < track.slots.count, let original = track.slots[scene] else { return }
        let targetScene = scene + 1
        let copy = duplicate(of: original)

        let insertedScene: Bool
        if targetScene >= sceneCount {
            insertScene(at: sceneCount)
            insertedScene = true
        } else if track.slots[targetScene] != nil {
            insertScene(at: targetScene)
            insertedScene = true
        } else {
            insertedScene = false
        }
        track.slots[targetScene] = copy
        markDirty()
        selectTrack(track)
        selectedScene = targetScene
        selectedSlot = SlotRef(trackID: track.id, scene: targetScene)

        registerUndo("Duplicate Clip") { engine in
            if insertedScene {
                engine.removeScene(at: targetScene)
            } else if targetScene < track.slots.count {
                track.slots[targetScene] = nil
            }
            engine.markDirty()
            engine.registerUndo("Duplicate Clip") { redo in
                redo.duplicateClipDown(clip, on: track, scene: scene)
            }
        }
    }

    /// A fresh copy sharing the (immutable) source audio, warped to the current
    /// tempo, with a new id.
    private func duplicate(of clip: Clip) -> Clip {
        let copy = Clip(name: clip.name, colorIndex: clip.colorIndex, buffer: clip.sourceBuffer,
                        loopBars: clip.loopBars, fileURL: clip.fileURL, nativeTempo: clip.nativeTempo)
        copy.applyTempo(tempo)
        return copy
    }

    /// DEL key / Track menu: delete the last-clicked clip.
    func deleteSelectedClip() {
        guard let slot = selectedSlot,
              let track = tracks.first(where: { $0.id == slot.trackID }),
              slot.scene < track.slots.count, track.slots[slot.scene] != nil else { return }
        deleteClip(on: track, scene: slot.scene)
    }

    func deleteClip(on track: Track, scene: Int) {
        guard let clip = track.slots[scene] else { return }
        if recordingSlot == SlotRef(trackID: track.id, scene: scene) { return }
        if selectedSlot == SlotRef(trackID: track.id, scene: scene) { selectedSlot = nil }
        if let state = playback[track.id],
           state.playingClipID == clip.id || state.queuedClipID == clip.id,
           let channel = graph.channel(for: track.id) {
            channel.pendingTask?.cancel()
            channel.stopAllPlayers()
            playback[track.id] = TrackPlayback()
        }
        track.slots[scene] = nil
        markDirty()
        registerUndo("Delete Clip") { engine in
            guard scene < track.slots.count, track.slots[scene] == nil else { return }
            track.slots[scene] = clip
            engine.markDirty()
            engine.registerUndo("Delete Clip") { $0.deleteClip(on: track, scene: scene) }
        }
    }

    func moveClip(from source: SlotRef, to destination: SlotRef) {
        guard source != destination,
              let sourceTrack = tracks.first(where: { $0.id == source.trackID }),
              let destinationTrack = tracks.first(where: { $0.id == destination.trackID }),
              recordingSlot != source, recordingSlot != destination else { return }
        let moving = sourceTrack.slots[source.scene]
        sourceTrack.slots[source.scene] = destinationTrack.slots[destination.scene]
        destinationTrack.slots[destination.scene] = moving
        markDirty()
        registerUndo("Move Clip") { $0.moveClip(from: destination, to: source) }
    }

    func handleClipDropPayload(_ payload: String, destination: SlotRef) {
        let parts = payload.split(separator: ":")
        guard parts.count == 3, parts[0] == "clipmove",
              let trackID = UUID(uuidString: String(parts[1])),
              let scene = Int(parts[2]) else { return }
        moveClip(from: SlotRef(trackID: trackID, scene: scene), to: destination)
    }

    func importAudioFile(_ url: URL, into track: Track, scene: Int) {
        guard recordingSlot == nil else { return }
        guard let clip = makeClip(fromFile: url, colorIndex: track.colorIndex) else { return }
        if track.slots[scene] != nil { deleteClip(on: track, scene: scene) }
        track.slots[scene] = clip
        markDirty()
    }

    private func makeClip(fromFile url: URL, colorIndex: Int) -> Clip? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(file.length)) else {
                throw NSError(domain: "SceneStack", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Empty or unreadable audio file"])
            }
            try file.read(into: raw)
            guard let buffer = AudioUtil.convert(raw, to: standardFormat) else {
                throw NSError(domain: "SceneStack", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"])
            }

            let seconds = Double(file.length) / file.processingFormat.sampleRate
            let beats = seconds * tempo / 60
            let bars = max(1, Int((beats / Double(beatsPerBar)).rounded()))
            statusMessage = nil
            // Treat the file as exactly `bars` bars: its native tempo is the one
            // at which that's true, so warping to the project tempo snaps it to
            // the grid (rather than looping at a slightly-off length).
            let nativeTempo = seconds > 0 ? Double(bars * beatsPerBar) * 60.0 / seconds : tempo
            let clip = Clip(name: url.deletingPathExtension().lastPathComponent,
                            colorIndex: colorIndex, buffer: buffer, loopBars: bars,
                            fileURL: url, nativeTempo: nativeTempo)
            clip.applyTempo(tempo)
            return clip
        } catch {
            statusMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    func allClips() -> [Clip] {
        var seen = Set<UUID>()
        var result: [Clip] = []
        for clip in tracks.flatMap({ $0.slots.compactMap { $0 } })
        where seen.insert(clip.id).inserted {
            result.append(clip)
        }
        return result
    }

    // MARK: - Project load support

    /// Tears down the session and rebuilds it from decoded project state.
    func replaceSession(tempo: Double, beatsPerBar: Int, countInBars: Int,
                        quantize: LaunchQuantize, sceneCount: Int,
                        masterVolume: Double, newTracks: [Track]) {
        stop()
        suppressDirty = true
        defer { suppressDirty = false; undoManager.removeAllActions(); hasUnsavedChanges = false }
        for track in tracks { deleteTrack(track) }
        self.tempo = tempo
        self.beatsPerBar = beatsPerBar
        self.countInBars = countInBars
        self.quantize = quantize
        self.scenes = (0..<max(0, sceneCount)).map { _ in SessionScene() }
        self.masterVolume = masterVolume
        for track in newTracks {
            graph.addChannel(for: track.id)
            tracks.append(track)
        }
        selectedTrackID = tracks.first?.id
        selectedSlot = nil
        selectedScene = sceneCount > 0 ? 0 : nil
        applyMixAll()
    }

    /// Resets to a fresh, empty 4-track / 4-scene project at defaults.
    func newProject() {
        let fresh = (0..<4).map {
            Track(name: "Track \($0 + 1)", colorIndex: $0 % 6, sceneCount: 4)
        }
        replaceSession(tempo: 120, beatsPerBar: 4, countInBars: 2, quantize: .bar,
                       sceneCount: 4, masterVolume: 0.9, newTracks: fresh)
        projectURL = nil
        statusMessage = "New project."
    }

    // MARK: - Beat/time mapping

    /// Next launch boundary in beats, always slightly in the future so the
    /// player start remains schedulable.
    func nextQuantizedBeat() -> Double {
        BeatMath.quantizedBoundary(afterBeats: currentBeats, tempo: tempo,
                                   beatsPerBar: beatsPerBar, quantize: quantize)
    }

    /// Approximate host time of a future beat, assuming the tempo holds
    /// between now and then (tempo changes mid-wait shift queued launches
    /// slightly; the next launch resyncs).
    func hostTime(forBeat beat: Double) -> UInt64 {
        let seconds = max(0.02, (beat - currentBeats) * 60.0 / tempo)
        return HostClock.now + HostClock.ticks(forSeconds: seconds)
    }

    /// Sleeps until the transport clock has actually reached `beat`. The
    /// clock starts on a future anchor, so a single duration computed up
    /// front wakes early — this loops against the authoritative clock (and
    /// self-corrects across tempo changes).
    func sleep(untilBeat beat: Double) async {
        while !Task.isCancelled, currentBeats < beat {
            if mode == .stopped { return }
            let seconds = max(0.002, (beat - currentBeats) * 60.0 / tempo)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    // MARK: - Devices

    /// The audio hardware changed under us — headphones in or out, an interface
    /// connected, the default device switched.
    ///
    /// AVAudioEngine stops itself and drops its I/O connections when this
    /// happens. Left alone the app looks dead afterwards: nothing plays and
    /// nothing records, because the graph is still attached but no longer
    /// wired to any hardware. So: stop cleanly, rebuild the connections,
    /// restart, and say what happened rather than failing silently.
    private func handleAudioConfigurationChange() {
        let wasRunning = mode != .stopped
        let wasRecording = mode == .recording
        stop()

        var effects: [UUID: [EffectInstance]] = [:]
        for track in tracks { effects[track.id] = track.effects }
        graph.reconnectAfterConfigurationChange(effects: effects)

        // The input node belongs to the old device; it has to be brought up
        // again before it can be recorded from or monitored.
        input.invalidate()
        startEngine()
        applyMonitoring()

        statusMessage = wasRecording
            ? "Audio device changed — recording stopped. Re-arm the track to continue."
            : wasRunning
              ? "Audio device changed — playback stopped. Press play to continue."
              : "Audio device changed."
    }

    private func handleDeviceListChange() {
        guard mode == .recording,
              !devices.inputDevices.contains(where: { $0.id == devices.selectedDeviceID })
        else { return }
        // The device we were capturing from disappeared: keep what we have.
        stop()
        input.teardown()
        applyMonitoring()   // the input is gone; tear the monitor path down too
        statusMessage = "Input device disconnected — recording stopped."
    }

    // MARK: - Engine lifecycle

    /// Stops the transport and tears down the audio graph.
    ///
    /// The app's engine lives as long as the process, so nothing calls this in
    /// normal use. It matters for anything that creates engines and lets them
    /// go — releasing one while its graph is still rendering leaves the audio
    /// thread calling into deallocated objects (`MetronomeSource`'s render
    /// block holds an `unowned` reference, as real-time code must: it can
    /// neither retain nor take a lock).
    func shutdown() {
        stop()
        graph.stop()
    }

    private func startEngine() {
        engineError = graph.start()
    }

    func ensureEngineRunning() {
        graph.ensureRunning()
    }
}
