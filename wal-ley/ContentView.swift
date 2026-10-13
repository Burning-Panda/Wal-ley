import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var manager: DatabaseManager

    private static let databaseTypes = ["sqlite", "sqlite3", "db"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        NavigationSplitView {
            SidebarView(manager: manager)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            detail
        }
        .navigationTitle(manager.metadata?.name ?? "wal-ley")
        .toolbar {
            Button("Open…", systemImage: "folder") { manager.showOpenPanel = true }
        }
        .fileImporter(isPresented: $manager.showOpenPanel, allowedContentTypes: Self.databaseTypes + [.database]) { result in
            if case .success(let url) = result { Task { await manager.open(url) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await manager.open(url) }
            return true
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    @ViewBuilder
    private var detail: some View {
        if !manager.isOpen {
            ContentUnavailableView {
                Label("No database", systemImage: "cylinder")
            } description: {
                Text(manager.errorMessage ?? "Open or drop a .sqlite, .sqlite3 or .db file.")
            }
        } else {
            switch manager.selection {
            case .console: ConsoleView(manager: manager)
            case .table: TableDataView(manager: manager)
            case nil: ContentUnavailableView("Select a table", systemImage: "tablecells")
            }
        }
    }
}
