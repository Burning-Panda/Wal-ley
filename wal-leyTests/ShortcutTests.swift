import SwiftUI
import Testing
@testable import wal_ley

struct ShortcutTests {
    @Test func symbolsReadLikeMenus() {
        #expect(KeyboardShortcut("s").symbols == "⌘S")
        #expect(KeyboardShortcut("w", modifiers: [.command, .shift]).symbols == "⇧⌘W")
        #expect(KeyboardShortcut(.return, modifiers: .command).symbols == "⌘↩")
        #expect(KeyboardShortcut("[").symbols == "⌘[")
        #expect(KeyboardShortcut.cancelAction.symbols == "esc")
        #expect(KeyboardShortcut("n", modifiers: [.control, .option, .shift, .command]).symbols == "⌃⌥⇧⌘N")
    }

    @Test func tooltipNamesTheActionAndKeys() {
        #expect(ShortcutButton.tooltip("Open a database file", KeyboardShortcut("o")) == "Open a database file  ⌘O")
    }

    @Test func underlinesTheShortcutLetter() {
        func underlined(_ title: String, _ shortcuts: [KeyboardShortcut]) -> [String] {
            let text = ShortcutButton.underlined(title, shortcuts)
            return text.runs.filter { $0.underlineStyle != nil }.map { String(text[$0.range].characters) }
        }
        #expect(underlined("Save", [KeyboardShortcut("s")]) == ["S"])
        #expect(underlined("Close Database", [KeyboardShortcut("w", modifiers: [.command, .shift])]) == [])
        // The first letter shortcut counts, even after a non-letter one.
        #expect(underlined("Open…", [KeyboardShortcut(.return, modifiers: .command), KeyboardShortcut("o")]) == ["O"])
        #expect(underlined("Run", [KeyboardShortcut(.return, modifiers: .command)]) == [])
    }
}
