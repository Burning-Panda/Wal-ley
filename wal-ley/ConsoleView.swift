import SwiftUI
import CodeEditorView
import LanguageSupport

struct ConsoleView: View {
    @Bindable var manager: DatabaseManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var position = CodeEditor.Position()
    @State private var messages: Set<TextLocated<Message>> = []

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                CodeEditor(text: $manager.consoleSQL,
                           position: $position,
                           messages: $messages,
                           language: .sqlite(manager.languageService))
                    .environment(\.codeEditorLayoutConfiguration, CodeEditor.LayoutConfiguration(showMinimap: false, wrapText: true))
                    .environment(\.codeEditorTheme, colorScheme == .dark ? Theme.defaultDark : Theme.defaultLight)
                Divider()
                HStack {
                    Spacer()
                    Button("Run", systemImage: "play.fill") { Task { await manager.runConsole(textToRun) } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(manager.consoleRunning)
                }
                .padding(8)
            }
            .frame(minHeight: 140)

            VStack(spacing: 0) {
                DataGridView(grid: manager.consoleGrid, tableName: "console", pending: [:],
                             editable: false, sortable: false, sort: nil)
                Divider()
                status.font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 140)
        }
    }

    /// The selection if there is one, otherwise the whole editor.
    private var textToRun: String {
        let source = manager.consoleSQL as NSString
        if let range = position.selections.first, range.length > 0, NSMaxRange(range) <= source.length {
            return source.substring(with: range)
        }
        return manager.consoleSQL
    }

    @ViewBuilder
    private var status: some View {
        if let error = manager.consoleError {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
        } else {
            Text(manager.consoleStatus ?? "⌘↩ to run").foregroundStyle(.secondary)
        }
    }
}
