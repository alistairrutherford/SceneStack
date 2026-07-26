import SwiftUI

struct ContentView: View {
    @Environment(TransportEngine.self) private var engine

    var body: some View {
        VStack(spacing: 0) {
            TransportBar()
                .padding(.horizontal, 20)
                .padding(.top, 16)

            SessionGridView()
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .resignsTextFieldFocusOnTap()

            ClipDetailBar()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            DeviceChainBar()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            InputBar()
                .padding(.horizontal, 20)

            statusBar
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .frame(minWidth: 1080, minHeight: 720)
        .background(Theme.backgroundGradient.ignoresSafeArea())
        // Keyboard-focus rings on sliders/buttons read as phantom "track
        // selection" highlights — suppress focus visuals app-wide.
        .focusEffectDisabled()
        .onDeleteKey(isEnabled: { engine.selectedSlot != nil }) {
            engine.deleteSelectedClip()
        }
        .clearsInitialTextFocus()
    }

    /// Fixed-height status strip: errors in coral, transient messages in
    /// amber, otherwise the shortcut hint — no layout jumps.
    private var statusBar: some View {
        HStack(spacing: 8) {
            if let error = engine.engineError {
                Circle().fill(Theme.coral).frame(width: 6, height: 6)
                Text(error).foregroundStyle(Theme.coral)
            } else if let status = engine.statusMessage {
                Circle().fill(Theme.amber).frame(width: 6, height: 6)
                Text(status).foregroundStyle(Theme.amber)
            } else {
                Text("SceneStack 1.0 — space play · R record · 1–9 scenes · A–L clips · ⌘S save")
                    .foregroundStyle(Theme.dimmed)
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface.opacity(0.8))
        )
    }
}
