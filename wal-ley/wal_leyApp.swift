import SwiftUI
import Sparkle

@main
struct wal_leyApp: App {
    @State private var manager = DatabaseManager()
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        // Kept to one window (see SingleWindow): everything shares one DatabaseManager.
        WindowGroup {
            ContentView(manager: manager)
                .background(SingleWindow())
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Database…") { Task { await manager.requestNewDatabase() } }
                    .keyboardShortcut("n")
                Button("New Table…") { manager.showNewTable = true }
                    .keyboardShortcut("t")
                    .disabled(!manager.isOpen || manager.isReadOnly)
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
                    .keyboardShortcut("w")
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
