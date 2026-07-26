import SwiftUI
import AppKit
import AVFoundation
import CoreAudioKit

/// Floating editor panels for AU effects, one per effect instance. Uses the
/// plugin's own view controller when it provides one, otherwise a generic
/// parameter list built from the AU's parameter tree.
@MainActor
enum PluginWindows {
    private static var panels: [UUID: NSPanel] = [:]

    static func open(for effect: EffectInstance) {
        if let panel = panels[effect.id] {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let auUnit = effect.node.auAudioUnit
        let title = "\(effect.name) — \(effect.manufacturer)"
        auUnit.requestViewController { viewController in
            DispatchQueue.main.async {
                let content = viewController ?? NSHostingController(
                    rootView: GenericAUView(auUnit: auUnit)
                        .frame(minWidth: 360, minHeight: 240))
                let panel = NSPanel(contentViewController: content)
                panel.title = title
                panel.styleMask.insert([.utilityWindow, .resizable])
                panel.isReleasedWhenClosed = false
                panel.makeKeyAndOrderFront(nil)
                panels[effect.id] = panel
            }
        }
    }

    static func close(_ id: UUID) {
        panels[id]?.close()
        panels[id] = nil
    }
}

/// Fallback editor: a slider per parameter from the AU's parameter tree.
struct GenericAUView: View {
    let auUnit: AUAudioUnit

    private var parameters: [AUParameter] {
        auUnit.parameterTree?.allParameters.filter { $0.minValue < $0.maxValue } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if parameters.isEmpty {
                    Text("This effect has no adjustable parameters.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(parameters, id: \.address) { parameter in
                        ParameterSlider(parameter: parameter)
                    }
                }
            }
            .padding(14)
        }
        .background(Theme.surface)
    }
}

private struct ParameterSlider: View {
    let parameter: AUParameter
    @State private var value: Double

    init(parameter: AUParameter) {
        self.parameter = parameter
        _value = State(initialValue: Double(parameter.value))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(parameter.displayName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)
            Slider(value: $value,
                   in: Double(parameter.minValue)...Double(parameter.maxValue))
                .controlSize(.small)
                .tint(Theme.cyan)
                .onChange(of: value) { _, newValue in
                    parameter.value = AUValue(newValue)
                }
            Text(String(format: "%.2f", value))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
