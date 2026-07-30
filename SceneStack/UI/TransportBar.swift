import SwiftUI

/// Play/stop/record, position readout, tempo, time signature, count-in and
/// metronome controls.
struct TransportBar: View {
    @Environment(TransportEngine.self) private var engine
    @State private var dragStartTempo: Double?
    /// Editable text while the BPM field has focus; only applied to the engine
    /// on Return (never live, never on focus loss).
    @State private var tempoDraft = ""
    @FocusState private var tempoFieldFocused: Bool

    /// The current tempo as the whole-number string the field displays.
    private var tempoString: String { String(Int(engine.tempo)) }

    var body: some View {
        @Bindable var engine = engine

        HStack(spacing: 16) {
            transportButtons

            divider
            positionReadout
            divider

            Spacer(minLength: 12)

            tempoControl
            divider
            timeSignatureMenu
            recordLengthMenu
            quantizeMenu
            divider
            metronomeControls(volume: $engine.metronomeVolume)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
    }

    private var divider: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.08))
            .frame(width: 2, height: 30)
    }

    // MARK: - Transport buttons

    private var transportButtons: some View {
        HStack(spacing: 10) {
            TransportButton(
                systemImage: "play.fill",
                isActive: engine.mode == .playing,
                activeColor: Theme.mint
            ) {
                engine.togglePlayStop()
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / stop (space)")

            TransportButton(
                systemImage: "stop.fill",
                isActive: false,
                activeColor: Theme.dimmed
            ) {
                engine.stop()
            }
            .help("Stop")

            TransportButton(
                systemImage: "record.circle",
                isActive: engine.mode == .recording,
                activeColor: Theme.coral
            ) {
                engine.record()
            }
            .keyboardShortcut("r", modifiers: [])
            .disabled(!recordEnabled)
            .opacity(recordEnabled ? 1 : 0.35)
            .help(recordEnabled
                  ? "Record into the selected cell (R)"
                  : "Arm the selected track to enable recording")
        }
    }

    /// Record is possible only while stopped/playing with an armed target.
    private var recordEnabled: Bool {
        engine.mode == .recording || engine.canRecord
    }

    // MARK: - Position

    private var positionReadout: some View {
        TimelineView(.animation) { _ in
            let accent = Theme.accent(for: engine.mode, countingIn: engine.isCountingIn)
            HStack(spacing: 12) {
                Text(positionText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .frame(minWidth: 96, alignment: .leading)
                beatDots(accent: accent)
            }
        }
    }

    private func beatDots(accent: Color) -> some View {
        let beats = engine.currentBeats
        let displayBeats = beats < 0 ? beats + Double(engine.activeCountInBeats) : beats
        let activeIndex = engine.mode == .stopped ? -1 : Int(max(0, displayBeats)) % engine.beatsPerBar
        let fraction = displayBeats - displayBeats.rounded(.down)

        return HStack(spacing: 7) {
            ForEach(0..<engine.beatsPerBar, id: \.self) { index in
                let isActive = index == activeIndex
                Circle()
                    .fill(isActive ? accent : Theme.surfaceRaised)
                    .frame(width: index == 0 ? 11 : 9, height: index == 0 ? 11 : 9)
                    .scaleEffect(isActive ? 1.35 - 0.35 * fraction : 1)
                    .shadow(color: isActive ? accent.opacity(0.7) : .clear, radius: 5)
            }
        }
    }

    private var positionText: String {
        let beats = engine.currentBeats
        if engine.mode == .stopped { return "1.1.1" }
        if beats < 0 {
            // Counting in: plain countdown of bars remaining (e.g. 2 → 1).
            let elapsed = beats + Double(engine.activeCountInBeats)
            let barsRemaining = engine.countInBars - Int(elapsed) / engine.beatsPerBar
            return "\(max(1, barsRemaining))"
        }
        let whole = Int(beats)
        let bar = whole / engine.beatsPerBar + 1
        let beat = whole % engine.beatsPerBar + 1
        let sixteenth = Int((beats - Double(whole)) * 4) + 1
        return "\(bar).\(beat).\(sixteenth)"
    }

    // MARK: - Tempo

    private var tempoControl: some View {
        HStack(spacing: 5) {
            tempoStepButton("minus") { engine.tempo -= 1 }

            VStack(spacing: 0) {
                TextField("", text: $tempoDraft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.cyan)
                    .frame(width: 54)
                    .focused($tempoFieldFocused)
                    .onSubmit(commitTempoDraft)
                    .onExitCommand { tempoFieldFocused = false }
                Text("BPM")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.dimmed)
                    // Without this the label wraps to one letter per line when
                    // the transport bar is compressed at the minimum window size.
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            // Highlight the field while it's being edited, so it's clear the
            // typed value isn't live until Return.
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.cyan.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.cyan, lineWidth: 1.5)
                    )
                    .opacity(tempoFieldFocused ? 1 : 0)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragStartTempo == nil { dragStartTempo = engine.tempo }
                        engine.tempo = (dragStartTempo! - value.translation.height * 0.5).rounded()
                    }
                    .onEnded { _ in dragStartTempo = nil }
            )
            .onAppear { tempoDraft = tempoString }
            // Seed the draft when editing begins; discard it (revert to the
            // engine value) when focus leaves without a Return.
            .onChange(of: tempoFieldFocused) { _, _ in tempoDraft = tempoString }
            // Keep the display in step with −/+ and drag changes when not editing.
            .onChange(of: engine.tempo) { _, _ in
                if !tempoFieldFocused { tempoDraft = tempoString }
            }

            tempoStepButton("plus") { engine.tempo += 1 }
        }
        // Tempo is locked while recording — changing it mid-take would desync
        // the capture from the clock it's being trimmed against.
        .disabled(engine.mode == .recording)
        .opacity(engine.mode == .recording ? 0.4 : 1)
        .help(engine.mode == .recording
              ? "Tempo is locked while recording"
              : "Type a BPM, use −/+, or drag the number up/down")
    }

    /// Applies the typed BPM on Return. Invalid input is ignored; the engine
    /// clamps the value, and the focus-change handler re-syncs the display.
    private func commitTempoDraft() {
        if let value = Double(tempoDraft.trimmingCharacters(in: .whitespaces)) {
            engine.tempo = value
        }
        tempoFieldFocused = false
    }

    private func tempoStepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Theme.cyan.opacity(0.85))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.surfaceRaised))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Time signature

    private var timeSignatureMenu: some View {
        Menu {
            ForEach([2, 3, 4, 5, 6, 7], id: \.self) { beats in
                Button("\(beats)/4") { engine.beatsPerBar = beats }
            }
        } label: {
            VStack(spacing: 0) {
                Text("\(engine.beatsPerBar)/4")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.violet)
                Text("SIG")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.dimmed)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Time signature")
    }

    private var recordLengthMenu: some View {
        Menu {
            Button("Free") { engine.recordLengthBars = nil }
            ForEach([1, 2, 4, 8], id: \.self) { bars in
                Button("\(bars) bar\(bars == 1 ? "" : "s")") { engine.recordLengthBars = bars }
            }
        } label: {
            VStack(spacing: 0) {
                Text(engine.recordLengthBars.map(String.init) ?? "free")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.coral)
                Text("REC BARS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.dimmed)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Fixed recording length — the clip auto-finishes and keeps looping after this many bars")
    }

    private var quantizeMenu: some View {
        Menu {
            ForEach(LaunchQuantize.allCases) { option in
                Button(option.rawValue) { engine.quantize = option }
            }
        } label: {
            VStack(spacing: 0) {
                Text(engine.quantize == .none ? "off" : engine.quantize.rawValue.lowercased())
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.mint)
                Text("QUANTIZE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.dimmed)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Clip launch quantisation")
    }

    // MARK: - Count-in & metronome

    /// The count-in sits with the metronome rather than with the other menus:
    /// it's the click that counts you in, so they read as one group. It leads
    /// the group so the metronome's on/off button and its volume slider stay
    /// adjacent to each other.
    private func metronomeControls(volume: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            countInMenu

            TransportButton(
                systemImage: "metronome.fill",
                isActive: engine.metronomeEnabled,
                activeColor: Theme.cyan
            ) {
                engine.metronomeEnabled.toggle()
            }
            .help("Metronome on/off")

            Slider(value: volume, in: 0...1)
                .frame(width: 80)
                .tint(Theme.cyan)
                .help("Metronome volume")
        }
    }

    private var countInMenu: some View {
        Menu {
            ForEach([0, 1, 2, 4], id: \.self) { bars in
                Button(bars == 0 ? "None" : "\(bars) bar\(bars == 1 ? "" : "s")") {
                    engine.countInBars = bars
                }
            }
        } label: {
            VStack(spacing: 0) {
                Text(engine.countInBars == 0 ? "off" : "\(engine.countInBars)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.amber)
                Text("COUNT-IN")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.dimmed)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Count-in length before recording")
    }
}

/// A rounded square icon button that lights up in its accent colour.
private struct TransportButton: View {
    let systemImage: String
    let isActive: Bool
    let activeColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isActive ? Color.black.opacity(0.8) : activeColor.opacity(0.9))
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive ? AnyShapeStyle(activeColor) : AnyShapeStyle(Theme.surfaceRaised))
                )
                .shadow(color: isActive ? activeColor.opacity(0.6) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isActive)
    }
}
