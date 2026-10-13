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
            Button("Close Database", systemImage: "eject") { Task { await manager.requestClose() } }
                .disabled(!manager.isOpen)
        }
        .confirmationDialog("You have unsaved changes", isPresented: unsavedBinding, titleVisibility: .visible) {
            Button("Save") { resolveUnsaved(save: true) }
            Button("Discard Changes", role: .destructive) { resolveUnsaved(save: false) }
            Button("Cancel", role: .cancel) { manager.unsavedPrompt = nil }
        } message: {
            Text("\(manager.pendingCount) edits or deletions haven't been written to the file.")
        }
        .fileImporter(isPresented: $manager.showOpenPanel, allowedContentTypes: Self.databaseTypes + [.database]) { result in
            if case .success(let url) = result { Task { await manager.requestOpen(url) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await manager.requestOpen(url) }
            return true
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var unsavedBinding: Binding<Bool> {
        Binding(get: { manager.unsavedPrompt != nil }, set: { if !$0 { manager.unsavedPrompt = nil } })
    }

    private func resolveUnsaved(save: Bool) {
        guard let action = manager.unsavedPrompt else { return }
        manager.unsavedPrompt = nil
        Task {
            if save { await manager.saveChanges() } else { manager.discardChanges() }
            // A failed save keeps the pending changes, so don't continue and lose them.
            if manager.pendingCount == 0 { await action() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !manager.isOpen {
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label("No database", systemImage: "cylinder")
                } description: {
                    Text(manager.errorMessage ?? "Open or drop a .sqlite, .sqlite3 or .db file.")
                }
                if !manager.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent").font(.headline)
                        ForEach(manager.recents.prefix(8), id: \.self) { url in
                            Button { Task { await manager.requestOpen(url) } } label: {
                                Label(url.lastPathComponent, systemImage: "clock")
                            }
                            .buttonStyle(.link)
                            .help(url.path)
                        }
                    }
                    .padding(.bottom, 40)
                }
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
