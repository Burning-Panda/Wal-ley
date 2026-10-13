import SwiftUI

@main
struct wal_leyApp: App {
    @State private var manager = DatabaseManager()

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { manager.showOpenPanel = true }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Changes") { Task { await manager.saveChanges() } }
                    .keyboardShortcut("s")
                    .disabled(manager.pendingChanges.isEmpty)
                Button("Discard Changes") { manager.discardChanges() }
                    .disabled(manager.pendingChanges.isEmpty)
            }
            CommandMenu("Query") {
                Button("SQL Console") { manager.selection = .console }
                    .keyboardShortcut("k")
                    .disabled(!manager.isOpen)
            }
        }
    }
}
