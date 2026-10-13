import SwiftUI

@main
struct wal_leyApp: App {
    @State private var manager = DatabaseManager()

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { manager.showOpenPanel = true }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(manager.recents, id: \.self) { url in
                        Button(url.lastPathComponent) { Task { await manager.requestOpen(url) } }
                    }
                    if !manager.recents.isEmpty { Divider() }
                    Button("Clear Menu") { manager.clearRecents() }
                        .disabled(manager.recents.isEmpty)
                }
                Button("Close Database") { Task { await manager.requestClose() } }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!manager.isOpen)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Changes") { Task { await manager.saveChanges() } }
                    .keyboardShortcut("s")
                    .disabled(manager.pendingCount == 0)
                Button("Discard Changes") { manager.discardChanges() }
                    .disabled(manager.pendingCount == 0)
            }
            CommandMenu("Query") {
                Button("SQL Console") { manager.selection = .console }
                    .keyboardShortcut("k")
                    .disabled(!manager.isOpen)
            }
        }
    }
}
