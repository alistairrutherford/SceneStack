import SwiftUI
import AVFoundation

/// The selected track's insert-effect chain: one chip per AU, in processing
/// order, plus a searchable browser to add more.
struct DeviceChainBar: View {
    @Environment(TransportEngine.self) private var engine
    @State private var showBrowser = false

    var body: some View {
        HStack(spacing: 12) {
            label
            divider

            if let track = engine.selectedTrack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if track.effects.isEmpty {
                            Text("No effects — click + to add an Audio Unit")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.dimmed)
                        }
                        ForEach(track.effects) { effect in
                            EffectChip(effect: effect, track: track)
                        }
                    }
                }

                Button {
                    showBrowser = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.violet)
                }
                .buttonStyle(.plain)
                .help("Add an AU effect")
                .popover(isPresented: $showBrowser, arrowEdge: .top) {
                    EffectBrowser(track: track)
                }
            } else {
                Text("Add a track to use effects")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.dimmed)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
    }

    private var label: some View {
        let track = engine.selectedTrack
        let color = track.map { Theme.trackPalette[$0.colorIndex % Theme.trackPalette.count] } ?? Theme.dimmed
        return VStack(alignment: .leading, spacing: 0) {
            Text(track?.name ?? "—")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
            Text("FX CHAIN")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Theme.dimmed)
        }
        .frame(width: 96, alignment: .leading)
    }

    private var divider: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.08))
            .frame(width: 2, height: 30)
    }
}

// MARK: - Effect chip

private struct EffectChip: View {
    @Environment(TransportEngine.self) private var engine
    let effect: EffectInstance
    let track: Track

    var body: some View {
        HStack(spacing: 6) {
            Button {
                effect.isBypassed.toggle()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(effect.isBypassed ? Theme.dimmed : Theme.mint)
            }
            .buttonStyle(.plain)
            .help(effect.isBypassed ? "Enable" : "Bypass")

            Button {
                PluginWindows.open(for: effect)
            } label: {
                Text(effect.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(effect.isBypassed ? 0.4 : 0.92))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open editor")

            HStack(spacing: 2) {
                Button {
                    engine.moveEffect(effect, in: track, by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Theme.dimmed)
                }
                .buttonStyle(.plain)
                .help("Move earlier in chain")

                Button {
                    engine.moveEffect(effect, in: track, by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Theme.dimmed)
                }
                .buttonStyle(.plain)
                .help("Move later in chain")
            }

            Button {
                engine.removeEffect(effect, from: track)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Theme.dimmed)
            }
            .buttonStyle(.plain)
            .help("Remove effect")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.violet.opacity(effect.isBypassed ? 0.15 : 0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.violet.opacity(effect.isBypassed ? 0.2 : 0.55), lineWidth: 1)
                )
        )
    }
}

// MARK: - Browser

private struct EffectBrowser: View {
    @Environment(TransportEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var query = ""
    @State private var components: [AVAudioUnitComponent] = []

    private var filtered: [AVAudioUnitComponent] {
        guard !query.isEmpty else { return components }
        return components.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.manufacturerName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search effects…", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered, id: \.self) { component in
                        Button {
                            engine.addEffect(component, to: track)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(component.name)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(component.manufacturerName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300, height: 380)
        .onAppear { components = engine.effectComponents() }
    }
}
