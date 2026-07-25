import SwiftUI
import UniformTypeIdentifiers

private enum GridMetrics {
    static let cellWidth: CGFloat = 136
    static let cellHeight: CGFloat = 46
    static let headerHeight: CGFloat = 124
    static let sceneNumberWidth: CGFloat = 22
    static let sceneWidth: CGFloat = 44
    static let sceneStopWidth: CGFloat = 30
    static let spacing: CGFloat = 7
    /// Full width of the scene number + launch + stop column group.
    static var sceneAreaWidth: CGFloat {
        sceneNumberWidth + spacing + sceneWidth + spacing + sceneStopWidth
    }
}

/// The Ableton-style session view: tracks as columns, scenes as rows.
struct SessionGridView: View {
    @Environment(TransportEngine.self) private var engine
    @FocusState private var gridFocused: Bool

    var body: some View {
        // A two-axis ScrollView centres content that is smaller than its
        // viewport while still laying it out — and hit-testing it — from the
        // top-leading corner. Drawing and input then disagree, and every click
        // lands a column to the right of whatever is under the cursor. Anchoring
        // the scroll view top-leading, and letting a trailing spacer absorb any
        // slack inside the row, keeps the two in step at every window size
        // (including when the content is larger than the viewport and the
        // scroll view proposes an unbounded width).
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: GridMetrics.spacing + 3) {
                sceneColumn
                ForEach(engine.tracks) { track in
                    TrackColumn(track: track)
                }
                addTrackButton
                Spacer(minLength: 0)
            }
            .overlay(alignment: .topLeading) { sceneHighlight }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .defaultScrollAnchor(.topLeading)
        // Performance launching is scoped to the grid's keyboard focus: plain
        // keys only launch while the session view is the active surface, and
        // clicking into any text field hands focus off so typing works.
        .focusable()
        .focused($gridFocused)
        .onAppear { gridFocused = true }
        .onKeyPress { press in
            guard press.modifiers.isEmpty, let character = press.characters.first,
                  engine.performLaunchKey(character) else { return .ignored }
            return .handled
        }
    }

    /// Selected-scene outline. The grid is built as columns, so the row box
    /// is drawn as an overlay positioned from the fixed grid metrics — it
    /// spans the scene launcher and every track column.
    @ViewBuilder
    private var sceneHighlight: some View {
        if let scene = engine.selectedScene, scene < engine.sceneCount {
            let columnStep = GridMetrics.cellWidth + GridMetrics.spacing + 3
            let width = GridMetrics.sceneAreaWidth + CGFloat(engine.tracks.count) * columnStep
            let y = GridMetrics.headerHeight + GridMetrics.spacing
                + CGFloat(scene) * (GridMetrics.cellHeight + GridMetrics.spacing)

            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.violet.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Theme.violet.opacity(0.7), lineWidth: 2)
                )
                .frame(width: width + 6, height: GridMetrics.cellHeight + 6)
                .offset(x: -3, y: y - 3)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Scene launch column

    private var sceneColumn: some View {
        VStack(spacing: GridMetrics.spacing) {
            HStack(spacing: GridMetrics.spacing) {
                Text("#")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Theme.dimmed)
                    .frame(width: GridMetrics.sceneNumberWidth)
                Text("SCENES")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.dimmed)
                    .frame(width: GridMetrics.sceneWidth)
                Image(systemName: "stop")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Theme.dimmed)
                    .frame(width: GridMetrics.sceneStopWidth)
            }
            .frame(height: GridMetrics.headerHeight)

            ForEach(Array(engine.scenes.enumerated()), id: \.element.id) { scene, _ in
                SceneRow(scene: scene)
            }

            Button {
                engine.addScene()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.dimmed)
                    .frame(width: GridMetrics.sceneAreaWidth, height: 26)
            }
            .buttonStyle(.plain)
            .help("Add scene")
        }
    }

    private var addTrackButton: some View {
        Button {
            engine.addTrack()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text("TRACK")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.5)
            }
            .foregroundStyle(Theme.dimmed)
            .frame(width: 64, height: GridMetrics.headerHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            )
        }
        .buttonStyle(.plain)
        .help("Add track")
    }
}

// MARK: - Scene buttons

/// Consecutive scene number (always row index + 1, so it stays 1,2,3… after
/// any duplicate/delete). Right-click for scene duplicate/delete.
private struct SceneNumberLabel: View {
    @Environment(TransportEngine.self) private var engine
    let scene: Int

    var body: some View {
        Text("\(scene + 1)")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(engine.selectedScene == scene ? Theme.violet : Theme.dimmed)
            .frame(width: GridMetrics.sceneNumberWidth, height: GridMetrics.cellHeight)
            .contentShape(Rectangle())
            .onTapGesture { engine.selectScene(scene) }
            .onDrag { NSItemProvider(object: "scenemove:\(scene)" as NSString) }
            .contextMenu {
                // Structural edits are deferred until the menu has dismissed —
                // see `afterMenuDismissal`.
                Button("Duplicate Scene") {
                    afterMenuDismissal { engine.duplicateScene(scene) }
                }
                .disabled(!engine.sceneHasClips(scene))
                Divider()
                Button("Delete Scene", role: .destructive) {
                    afterMenuDismissal { engine.deleteScene(scene) }
                }
            }
            .help("Scene \(scene + 1) — drag to reorder · right-click to duplicate or delete")
    }
}

/// One scene row (number + launch + stop) that accepts a dragged scene to
/// reorder it here.
private struct SceneRow: View {
    @Environment(TransportEngine.self) private var engine
    let scene: Int
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: GridMetrics.spacing) {
            SceneNumberLabel(scene: scene)
            SceneLaunchButton(scene: scene)
            SceneStopButton(scene: scene)
        }
        .overlay(alignment: .top) {
            if dropTargeted {
                Capsule()
                    .fill(Theme.violet)
                    .frame(height: 3)
                    .offset(y: -4)
            }
        }
        .onDrop(of: [UTType.plainText], isTargeted: $dropTargeted) { providers in
            handleSceneDrop(providers, onto: scene)
        }
    }

    private func handleSceneDrop(_ providers: [NSItemProvider], onto target: Int) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            var payload: String?
            if let data = item as? Data { payload = String(data: data, encoding: .utf8) }
            else if let text = item as? String { payload = text }
            else if let text = item as? NSString { payload = text as String }
            guard let payload, payload.hasPrefix("scenemove:"),
                  let source = Int(payload.dropFirst("scenemove:".count)) else { return }
            Task { @MainActor in engine.moveScene(from: source, to: target) }
        }
        return true
    }
}

/// Scene launch triangle that pulses on each beat while the transport rolls,
/// like Ableton's animated launch buttons.
private struct SceneLaunchButton: View {
    @Environment(TransportEngine.self) private var engine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scene: Int

    private var isPlaying: Bool { engine.sceneIsPlaying(scene) }

    // The Button is deliberately built *outside* the pulse's `TimelineView`.
    // A TimelineView's content closure re-runs every display frame, so any
    // Button created inside it is torn down and rebuilt continuously — which
    // destroys an in-flight press and makes the button ignore clicks.
    var body: some View {
        Button {
            engine.launchScene(scene)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surface)
                pulseLayer
            }
            .frame(width: GridMetrics.sceneWidth, height: GridMetrics.cellHeight)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Launch scene \(scene + 1)")
    }

    /// Beat pulse for the row whose clips are actually playing. Purely
    /// decorative, and non-hit-testing, so the animation can never interfere
    /// with the button's own gesture handling.
    private var pulseLayer: some View {
        TimelineView(.animation(minimumInterval: nil,
                                paused: reduceMotion || engine.mode == .stopped || !isPlaying)) { _ in
            let beats = engine.currentBeats
            let playing = !reduceMotion && isPlaying && engine.mode != .stopped && beats >= 0
            // 1 at the start of each beat, decaying to 0 before the next.
            let pulse = playing ? pow(1 - (beats - beats.rounded(.down)), 2) : 0

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.violet.opacity(0.30 * pulse))
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.violet)
                    .scaleEffect(1 + 0.35 * pulse)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Clear (outlined) square scene-stop button that flashes briefly on click,
/// and triggers the same full stop as the main transport button.
private struct SceneStopButton: View {
    @Environment(TransportEngine.self) private var engine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scene: Int
    @State private var flashTrigger = 0

    var body: some View {
        Button {
            engine.selectScene(scene)
            engine.stop()
            if !reduceMotion { flashTrigger += 1 }
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.white.opacity(0.4), lineWidth: 1.5)
                // Flash the square white on click, then fade out — driven by
                // the trigger so there's no manual dispatch to reset it.
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white)
                        .phaseAnimator([0.0, 0.7, 0.0], trigger: flashTrigger) { fill, opacity in
                            fill.opacity(opacity)
                        } animation: { opacity in
                            opacity == 0.7 ? .linear(duration: 0.02) : .easeOut(duration: 0.35)
                        }
                }
                .frame(width: 15, height: 15)
                .frame(width: GridMetrics.sceneStopWidth, height: GridMetrics.cellHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Stop — same as the main stop button")
    }
}

/// Compact horizontal stereo VU meter for a track header. The meter is
/// post-fader, so the track's VOL slider controls its level.
private struct TrackMeter: View {
    @Environment(TransportEngine.self) private var engine
    let track: Track

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: engine.mode == .stopped)) { _ in
            let base = engine.mode == .stopped
                ? (left: 0.0, right: 0.0)
                : engine.meterLevels(for: track)
            // The meter tap is pre-pan, so reflect the knob with a balance
            // law: centre keeps both channels, turning fully to one side
            // silences the other.
            let pan = track.pan
            let leftGain = pan <= 0 ? 1.0 : max(0, 1 - pan)
            let rightGain = pan >= 0 ? 1.0 : max(0, 1 + pan)
            VStack(spacing: 2) {
                bar(level: base.left * leftGain)
                bar(level: base.right * rightGain)
            }
        }
        .frame(height: 8)
        .help("Output level (post-volume, reflects pan)")
    }

    private func bar(level: Double) -> some View {
        let fraction = min(1, pow(level, 0.5))
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.mint, Theme.amber, Theme.coral],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, proxy.size.width * fraction))
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
    }
}

// MARK: - Track column

private struct TrackColumn: View {
    @Environment(TransportEngine.self) private var engine
    let track: Track

    var body: some View {
        let color = Theme.trackPalette[track.colorIndex % Theme.trackPalette.count]
        let isSelected = engine.selectedTrackID == track.id

        VStack(spacing: GridMetrics.spacing) {
            TrackHeader(track: track)
            ForEach(Array(engine.scenes.enumerated()), id: \.element.id) { scene, _ in
                ClipCell(track: track, scene: scene)
            }
        }
        // Selection reads as a box around the whole column — header and
        // every clip — so it can't be mistaken for keyboard focus. Purely
        // decorative, so it must not intercept hover/clicks on the controls.
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? color.opacity(0.07) : .clear)
                .padding(-3)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isSelected ? color.opacity(0.7) : .clear, lineWidth: 2)
                .padding(-3)
                .allowsHitTesting(false)
        )
    }
}

private struct TrackHeader: View {
    @Environment(TransportEngine.self) private var engine
    let track: Track

    @State private var volumeDragStart: Double?
    @State private var isEditingName = false
    @State private var nameDraft = ""
    @FocusState private var nameFieldFocused: Bool

    private var color: Color { Theme.trackPalette[track.colorIndex % Theme.trackPalette.count] }

    var body: some View {
        VStack(spacing: 6) {
            trackTitle

            HStack(spacing: 6) {
                headerButton("record.circle", active: track.isArmed, color: Theme.coral) {
                    engine.toggleArm(track)
                }
                .help("Arm this track for recording (only one track can be armed at a time)")

                headerButton(track.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             active: track.isMuted, color: Theme.amber) {
                    engine.toggleMute(track)
                }
                .help(track.isMuted ? "Unmute" : "Mute")

                headerButton("s.square.fill", active: track.isSoloed, color: Theme.cyan) {
                    engine.toggleSolo(track)
                }
                .help("Solo — silence every other track so only this one plays")

                Spacer(minLength: 0)

                overdubToggle
            }

            HStack(spacing: 10) {
                sliderRow("VOL", value: Binding(
                    get: { track.volume },
                    set: { engine.setVolume(track, $0) }
                ), range: 0...1, onEditingChanged: { editing in
                    if editing {
                        volumeDragStart = track.volume
                    } else if let start = volumeDragStart {
                        engine.commitVolume(track, from: start)
                        volumeDragStart = nil
                    }
                })
                .help("Track volume")

                PanKnob(color: color, pan: Binding(
                    get: { track.pan },
                    set: { engine.setPan(track, $0) }
                ), onCommit: { previous in engine.commitPan(track, from: previous) })
            }

            TrackMeter(track: track)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: GridMetrics.cellWidth, height: GridMetrics.headerHeight)
        .background(
            VStack(spacing: 0) {
                Rectangle().fill(color).frame(height: 4)
                Rectangle().fill(Theme.surfaceRaised)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        )
        .contentShape(Rectangle())
        .onTapGesture { engine.selectTrack(track) }
        .contextMenu {
            Button("Rename…") { afterMenuDismissal { beginRenaming() } }
            Button("Delete Track", role: .destructive) {
                afterMenuDismissal { engine.deleteTrack(track) }
            }
        }
    }

    /// The track name — click to rename it inline. Editing commits on Return or
    /// when focus leaves; a blank name is rejected (the old name is kept).
    @ViewBuilder
    private var trackTitle: some View {
        if isEditingName {
            TextField("Track name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($nameFieldFocused)
                .onSubmit(commitRename)
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused { commitRename() }
                }
        } else {
            Text(track.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Only the double-click lives here. Single-click selection is
                // left to the header's own tap gesture that wraps this view —
                // stacking a second, competing tap recogniser on the title made
                // macOS mis-route clicks to a neighbouring column.
                .onTapGesture(count: 2) { beginRenaming() }
                .help("\(track.name) — click to select, double-click to rename. Right-click to delete this track.")
        }
    }

    private func beginRenaming() {
        engine.selectTrack(track)
        nameDraft = track.name
        isEditingName = true
        nameFieldFocused = true
    }

    /// Applies the edited name (the engine rejects blank/unchanged names) and
    /// leaves edit mode.
    private func commitRename() {
        guard isEditingName else { return }
        isEditingName = false
        engine.renameTrack(track, to: nameDraft)
    }

    /// Record-mode toggle for recording into an occupied cell, styled like
    /// the solo button: shows 'o' for Overdub (layer on top) or 'r' for
    /// Replace (clear & re-record), coloured by mode.
    private var overdubToggle: some View {
        headerButton(track.isOverdub ? "o.square.fill" : "r.square.fill",
                     active: true,
                     color: track.isOverdub ? Theme.mint : Theme.amber) {
            engine.toggleOverdub(track)
        }
        .help("Record mode when the cell already has a clip (click to toggle).\nO = Overdub: the existing clip plays and your new take is layered on top, same length.\nR = Replace: the existing clip is cleared and re-recorded from scratch.")
    }

    private func headerButton(_ symbol: String, active: Bool, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(active ? Color.black.opacity(0.8) : color)
                .frame(width: 26, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? AnyShapeStyle(color) : AnyShapeStyle(Theme.surface))
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func sliderRow(_ label: String, value: Binding<Double>,
                           range: ClosedRange<Double>,
                           onEditingChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(Theme.dimmed)
                .frame(width: 20, alignment: .leading)
            Slider(value: value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.mini)
                .tint(color)
                .focusable(false)
        }
    }
}

/// Rotary pan control: centre (0) points straight up, sweeping ±135° to hard
/// left/right. Drag vertically to turn; double-click re-centres.
private struct PanKnob: View {
    let color: Color
    @Binding var pan: Double
    /// Called on gesture end with the pre-gesture value, so the change can be
    /// registered as a single undo.
    var onCommit: (Double) -> Void = { _ in }
    @State private var dragStart: Double?

    private let sweep = 135.0

    private var angle: Double { pan * sweep }

    private var readout: String {
        if abs(pan) < 0.02 { return "C" }
        let side = pan < 0 ? "L" : "R"
        return "\(side)\(Int((abs(pan) * 100).rounded()))"
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(Theme.surface)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

                // Deflection arc from centre (12 o'clock) to the pointer.
                PanArc(pan: pan, sweep: sweep)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(3)

                // Pointer notch.
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 9)
                    .offset(y: -6)
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 30, height: 30)

            Text(readout)
                .font(.system(size: 7, weight: .heavy).monospacedDigit())
                .foregroundStyle(Theme.dimmed)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil { dragStart = pan }
                    let next = (dragStart ?? 0) - Double(value.translation.height) * 0.012
                    pan = min(max(next, -1), 1)
                }
                .onEnded { _ in
                    if let start = dragStart { onCommit(start) }
                    dragStart = nil
                }
        )
        .onTapGesture(count: 2) {
            let previous = pan
            pan = 0
            onCommit(previous)
        }
        .help("Pan — drag to turn · double-click to centre")
    }
}

/// Arc traced from 12 o'clock to the current pan position.
private struct PanArc: Shape {
    let pan: Double
    let sweep: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // SwiftUI angles measure from 3 o'clock; 12 o'clock is -90°.
        let top = Angle.degrees(-90)
        let target = Angle.degrees(-90 + pan * sweep)
        path.addArc(center: centre, radius: radius,
                    startAngle: min(top, target), endAngle: max(top, target),
                    clockwise: false)
        return path
    }
}

// MARK: - Clip cell

private struct ClipCell: View {
    @Environment(TransportEngine.self) private var engine
    let track: Track
    let scene: Int
    @State private var dropTargeted = false

    // Bounds-safe: a row view can briefly hold a stale index while the grid
    // reconciles after a scene is deleted.
    private var clip: Clip? { scene < track.slots.count ? track.slots[scene] : nil }
    private var slotRef: SlotRef { SlotRef(trackID: track.id, scene: scene) }
    private var state: TrackPlayback? { engine.playback[track.id] }
    private var isRecordingHere: Bool { engine.recordingSlot == slotRef }

    var body: some View {
        content
            .frame(width: GridMetrics.cellWidth, height: GridMetrics.cellHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(dropTargeted ? Theme.cyan : .clear, lineWidth: 2)
            )
            // Clicking anywhere in a cell selects that cell (track x, scene y)
            // so record and DEL always target it. Cell buttons run alongside.
            .simultaneousGesture(TapGesture().onEnded {
                engine.selectTrack(track)
                engine.selectScene(scene)
                engine.selectedSlot = slotRef
            })
            .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            }
    }

    @ViewBuilder
    private var content: some View {
        // While recording here, always show the recording indicator — even
        // over an occupied slot being replaced.
        if let clip, !isRecordingHere {
            FilledCell(clip: clip, track: track, scene: scene,
                       isRecordingHere: isRecordingHere)
        } else {
            emptyCell
        }
    }

    private var emptyCell: some View {
        Button {
            if isRecordingHere {
                engine.finishRecordingAndPlay()
            } else if engine.mode != .stopped {
                engine.stopClip(on: track)
            }
            // Otherwise just select the cell (handled by the cell gesture) —
            // recording is started only from the record button / R key.
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isRecordingHere ? Theme.coral.opacity(0.85) : Theme.surface)
                if isRecordingHere {
                    RecordingIndicator(queued: engine.recordQueuedUntilBeat != nil,
                                       countingIn: engine.isCountingIn)
                } else if track.isArmed {
                    Circle()
                        .strokeBorder(Theme.coral.opacity(0.8), lineWidth: 2)
                        .frame(width: 11, height: 11)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isRecordingHere
              ? "Recording — click to finish and loop"
              : "Click to select · use the record button to record here")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            let destinationTrack = track
            let destinationScene = scene
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                }
                guard let url else { return }
                Task { @MainActor in
                    engine.importAudioFile(url, into: destinationTrack, scene: destinationScene)
                }
            }
            return true
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            let destination = slotRef
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                var payload: String?
                if let data = item as? Data {
                    payload = String(data: data, encoding: .utf8)
                } else if let text = item as? String {
                    payload = text
                } else if let text = item as? NSString {
                    payload = text as String
                }
                guard let payload else { return }
                Task { @MainActor in
                    engine.handleClipDropPayload(payload, destination: destination)
                }
            }
            return true
        }
        return false
    }
}

/// A cell containing a clip: colour fill, waveform thumbnail, name, and
/// launch state (queued pulse, playing progress ring).
private struct FilledCell: View {
    @Environment(TransportEngine.self) private var engine
    let clip: Clip
    let track: Track
    let scene: Int
    let isRecordingHere: Bool
    @State private var isRenaming = false
    @State private var renameDraft = ""

    private var color: Color { Theme.trackPalette[clip.colorIndex % Theme.trackPalette.count] }
    private var state: TrackPlayback? { engine.playback[track.id] }
    private var isPlaying: Bool { state?.playingClipID == clip.id }
    private var isQueued: Bool { state?.queuedClipID == clip.id }

    // As with the scene launch button: the cell's Button and tap gesture must
    // live outside any `TimelineView`, or they are rebuilt every display frame
    // while the clip plays and stop responding reliably to clicks.
    var body: some View {
        cellBody
        .onDrag {
            NSItemProvider(object: "clipmove:\(track.id.uuidString):\(scene)" as NSString)
        }
        .contextMenu {
            Button("Rename…") {
                renameDraft = clip.name
                isRenaming = true
            }
            Button("Duplicate") {
                afterMenuDismissal { engine.duplicateClipDown(clip, on: track, scene: scene) }
            }
            .keyboardShortcut("d")
            Divider()
            Menu("Colour") {
                ForEach(0..<Theme.trackPalette.count, id: \.self) { index in
                    Button {
                        engine.setClipColor(clip, colorIndex: index)
                    } label: {
                        Label(Theme.paletteNames[index],
                              systemImage: clip.colorIndex == index ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            }
            Divider()
            Button("Delete Clip", role: .destructive) {
                afterMenuDismissal { engine.deleteClip(on: track, scene: scene) }
            }
        }
        .alert("Rename Clip", isPresented: $isRenaming) {
            TextField("Name", text: $renameDraft)
            Button("Rename") { engine.renameClip(clip, to: renameDraft) }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var slotRef: SlotRef { SlotRef(trackID: track.id, scene: scene) }

    private var cellBody: some View {
        let isSelected = engine.selectedSlot == slotRef

        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(isPlaying ? 1 : 0.68))

            WaveformShape(peaks: clip.waveform)
                .fill(Color.white.opacity(0.4))
                .padding(.horizontal, 6)
                .padding(.vertical, 7)

            HStack(spacing: 6) {
                playButton
                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.name)
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                    Text("\(clip.loopBars) bar\(clip.loopBars == 1 ? "" : "s")")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(0.65)
                }
                .foregroundStyle(Color.black.opacity(0.75))
                Spacer()
            }
            .padding(.horizontal, 6)
        }
        // Every per-frame animation lives here, isolated from the controls.
        .overlay { animatedLayer }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.white.opacity(0.9) : .clear, lineWidth: 2)
        )
        .shadow(color: isPlaying ? color.opacity(0.55) : .clear, radius: 7)
        .contentShape(Rectangle())
        // Cell selection is handled once, by the enclosing `ClipCell` — a second
        // tap recogniser here fired the same selection twice per click and
        // added avoidable gesture contention.
        .help(isQueued ? "Queued…" : "▶ launches · click selects · DEL deletes")
    }

    /// Follow line, progress ring and queued-pulse border — the parts that must
    /// redraw every frame. Non-hit-testing and free of any controls, so the
    /// cell's button and tap gesture keep stable identity while it plays.
    private var animatedLayer: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !(isPlaying || isQueued))) { _ in
            let beats = engine.currentBeats
            let queuedPulse = isQueued ? 0.35 + 0.65 * (1 - (beats - beats.rounded(.down))) : 0

            ZStack {
                // Ableton-style follow line sweeping the clip while it plays.
                if isPlaying {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 1.5)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                            .position(x: proxy.size.width * playFraction(beats: beats),
                                      y: proxy.size.height / 2)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 7)

                    HStack {
                        Spacer()
                        progressRing(beats: beats)
                    }
                    .padding(.horizontal, 6)
                }

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(queuedPulse), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    /// Live-style launch button — the only part of the cell that plays.
    private var playButton: some View {
        Button {
            engine.selectScene(scene)
            engine.selectedSlot = slotRef
            engine.launch(clip: clip, on: track)
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 19, height: 19)
                .background(Circle().fill(Color.white.opacity(isPlaying ? 0.9 : 0.55)))
        }
        .buttonStyle(.plain)
        .help("Launch clip")
    }

    /// Position through the current loop (0...1) for the follow line and ring.
    private func playFraction(beats: Double) -> Double {
        let loopBeats = Double(clip.loopBars * engine.beatsPerBar)
        guard loopBeats > 0 else { return 0 }
        let elapsed = beats - (state?.playingStartBeat ?? 0)
        return max(0, elapsed.truncatingRemainder(dividingBy: loopBeats)) / loopBeats
    }

    private func progressRing(beats: Double) -> some View {
        let fraction = playFraction(beats: beats)
        return ZStack {
            Circle()
                .stroke(Color.black.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Color.black.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
    }
}

/// Pulsing record indicator for a slot that is armed-and-recording.
private struct RecordingIndicator: View {
    let queued: Bool
    let countingIn: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.55 + 0.45 * sin(phase * 6)
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 10, height: 10)
                    .opacity(pulse)
                Text(queued || countingIn ? "…" : "REC")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.75))
            }
        }
    }
}

