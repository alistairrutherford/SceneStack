import SwiftUI

/// Bottom strip: input device picker, live level meter, and a workflow hint.
struct InputBar: View {
    @Environment(TransportEngine.self) private var engine

    var body: some View {
        @Bindable var engine = engine
        return HStack(spacing: 14) {
            inputPicker
            VStack(spacing: 5) {
                LevelMeter()
                Slider(value: $engine.inputGain, in: 0...2)
                    .controlSize(.mini)
                    .frame(width: 110)
                    .tint(Theme.cyan)
                    .help("Input level — gain applied to recorded audio")
            }
            divider
            hint
            divider
            MasterSection()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
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

    private var inputPicker: some View {
        Menu {
            ForEach(engine.devices.inputDevices) { device in
                Button {
                    engine.selectInputDevice(device.id)
                } label: {
                    if device.id == engine.devices.selectedDeviceID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(engine.mode == .recording ? Theme.coral : Theme.cyan)
                VStack(alignment: .leading, spacing: 0) {
                    Text(engine.devices.selectedDevice?.name ?? "No input")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text("INPUT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.dimmed)
                }
            }
            .frame(maxWidth: 190, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(engine.mode == .recording)
        .help("Recording input device")
    }

    private var hint: some View {
        Text(engine.armedTrack == nil
             ? "Arm a track (●), then click an empty slot to record a loop — or drop audio files onto the grid."
             : "Click an empty slot on \(engine.armedTrack!.name) to record · click the recording cell to finish and loop it.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.dimmed)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Master output: a stereo meter over the master volume fader.
private struct MasterSection: View {
    @Environment(TransportEngine.self) private var engine
    @State private var dragStart: Double?

    var body: some View {
        @Bindable var engine = engine
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.mint)
            VStack(alignment: .leading, spacing: 5) {
                MasterMeter()
                Slider(value: $engine.masterVolume, in: 0...1, onEditingChanged: { editing in
                    if editing {
                        dragStart = engine.masterVolume
                    } else if let start = dragStart {
                        engine.commitMasterVolume(from: start)
                        dragStart = nil
                    }
                })
                    .controlSize(.mini)
                    .frame(width: 120)
                    .tint(Theme.mint)
                    .help("Master output volume")
            }
        }
        .help("Master output")
    }
}

/// Stereo master output meter, polled from the master mixer tap.
private struct MasterMeter: View {
    @Environment(TransportEngine.self) private var engine

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: engine.mode == .stopped)) { _ in
            let levels = engine.mode == .stopped ? (left: 0.0, right: 0.0) : engine.masterMeter.levels
            VStack(spacing: 2) {
                bar(level: levels.left)
                bar(level: levels.right)
            }
        }
        .frame(width: 120, height: 8)
    }

    private func bar(level: Double) -> some View {
        let fraction = min(1, pow(level, 0.5))
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
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

/// Gradient input meter fed by the recording tap; lights up while capturing.
private struct LevelMeter: View {
    @Environment(TransportEngine.self) private var engine

    var body: some View {
        TimelineView(.animation) { _ in
            let capturing = engine.mode == .recording || engine.armedTrack != nil
            let level = capturing ? min(1, pow(engine.inputPeak, 0.5)) : 0

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
                GeometryReader { proxy in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.mint, Theme.amber, Theme.coral],
                                startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(0, proxy.size.width * level))
                }
                .clipShape(Capsule())
            }
            .frame(width: 110, height: 8)
            .opacity(capturing ? 1 : 0.4)
        }
        .help("Input level")
    }
}
