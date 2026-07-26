import SwiftUI

@main
struct SceneStackApp: App {
    @State private var engine = TransportEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { ProjectStore.newProjectWithPrompt(engine: engine) }
                    .keyboardShortcut("n")
                Divider()
                Button("Open Project…") { ProjectStore.openWithPanel(engine: engine) }
                    .keyboardShortcut("o")
                Button("Save Project") { engine.saveInPlace() }
                    .keyboardShortcut("s")
                Button("Save Project As…") { ProjectStore.saveWithPanel(engine: engine) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            // The demo set is a way in rather than a document command, so it
            // lives under Help. This also replaces the default "SceneStack
            // Help" item, which has no help book behind it.
            CommandGroup(replacing: .help) {
                Button("Load Demo Set") { ProjectStore.loadDemoSetWithPrompt(engine: engine) }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { engine.undoManager.undo() }
                    .keyboardShortcut("z")
                Button("Redo") { engine.undoManager.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Track") {
                Button("Arm Selected Track") {
                    if let track = engine.selectedTrack { engine.toggleArm(track) }
                }
                .keyboardShortcut("a", modifiers: [.option])
                Button("Mute Selected Track") {
                    if let track = engine.selectedTrack { engine.toggleMute(track) }
                }
                .keyboardShortcut("m", modifiers: [.option])
                Button("Solo Selected Track") {
                    if let track = engine.selectedTrack { engine.toggleSolo(track) }
                }
                .keyboardShortcut("s", modifiers: [.option])
                Divider()
                Button("Duplicate Selected Clip") { engine.duplicateSelectedClip() }
                    .keyboardShortcut("d")
                Button("Delete Selected Clip") { engine.deleteSelectedClip() }
                    .keyboardShortcut(.delete, modifiers: [.command])
            }
        }
    }
}
