import SwiftUI
import AppKit

// Isolates the few AppKit escape hatches the UI needs (global key handling
// and resigning text-field focus) behind SwiftUI modifiers, so views stay
// declarative and the event monitor's lifecycle is managed correctly.

/// Runs a structural edit *after* the current AppKit event finishes.
///
/// A `.contextMenu` action runs while AppKit is still tracking the menu. If it
/// mutates the collection behind a `ForEach` (adding/removing a scene, clip or
/// track), SwiftUI rebuilds the hierarchy mid-tracking and AppKit is left
/// routing clicks to views that no longer exist — buttons stop responding and
/// clicks land on a neighbouring column. Deferring one runloop turn lets the
/// menu dismiss and the event finish before the view tree changes underneath it.
@MainActor
func afterMenuDismissal(_ action: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async(execute: action)
}

/// True while a text field has keyboard focus — an editing field puts AppKit's
/// field editor in the responder chain. Global key handling (clip launching,
/// the delete key) checks this so ordinary typing isn't stolen: a track name or
/// tempo containing "a" or "4" must not launch a clip or a scene.
@MainActor
var isEditingTextField: Bool {
    NSApp.keyWindow?.firstResponder is NSTextView
}

extension View {
    /// Invokes `action` on Delete / Forward-Delete, unless a text field is
    /// being edited and only while `isEnabled` returns true. The underlying
    /// local event monitor is added and removed with the view, so it can't
    /// leak the way a bare `addLocalMonitorForEvents` in `onAppear` would.
    func onDeleteKey(isEnabled: @escaping () -> Bool,
                     perform action: @escaping () -> Void) -> some View {
        modifier(DeleteKeyMonitor(isEnabled: isEnabled, action: action))
    }

    /// Clears any text field that AppKit auto-focuses when the window first
    /// appears (the BPM field, being the first text field, otherwise launches
    /// in edit mode). Runs once, after the window has had a chance to become key.
    func clearsInitialTextFocus() -> some View {
        onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let window = NSApp.keyWindow ?? NSApp.windows.first,
                      window.firstResponder is NSTextView else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    /// Drops keyboard focus from an editing text field when the view is
    /// tapped — but only while a field is actually being edited, so it
    /// doesn't churn the responder chain on every click.
    func resignsTextFieldFocusOnTap() -> some View {
        simultaneousGesture(TapGesture().onEnded {
            DispatchQueue.main.async {
                guard let window = NSApp.keyWindow,
                      window.firstResponder is NSTextView else { return }
                window.makeFirstResponder(nil)
            }
        })
    }
}

private struct DeleteKeyMonitor: ViewModifier {
    let isEnabled: () -> Bool
    let action: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let isDeleteKey = event.keyCode == 51 || event.keyCode == 117
                    guard isDeleteKey, !isEditingTextField, isEnabled() else { return event }
                    action()
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
