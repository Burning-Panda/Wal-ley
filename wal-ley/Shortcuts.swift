import SwiftUI
import AppKit

/// Whether shortcut hints are showing: after ⌘ alone has been held briefly. Pressing any key (using a
/// shortcut) or another modifier hides them until ⌘ is pressed again.
@MainActor
@Observable
final class ShortcutHints {
    static let shared = ShortcutHints()

    private(set) var visible = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            MainActor.assumeIsolated { ShortcutHints.shared.handle(event) }
            return event
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ShortcutHints.shared.hide() }
        }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.type == .flagsChanged, modifiers == .command else { return hide() }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { visible = true }
        }
    }

    private func hide() {
        pending?.cancel()
        visible = false
    }
}

extension KeyboardShortcut {
    /// As menus show it, e.g. ⇧⌘W or ⌘↩.
    var symbols: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key.character {
        case KeyEquivalent.return.character: text += "↩"
        case KeyEquivalent.escape.character: text += "esc"
        case KeyEquivalent.delete.character: text += "⌫"
        case KeyEquivalent.tab.character: text += "⇥"
        case KeyEquivalent.leftArrow.character: text += "←"
        case KeyEquivalent.rightArrow.character: text += "→"
        default: text += String(key.character).uppercased()
        }
        return text
    }
}

/// A button whose shortcuts reveal themselves while ⌘ is held: a badge with the keys, and the shortcut's letter
/// underlined in the title. The first shortcut is the one shown; any others trigger the same action.
struct ShortcutButton: View {
    let title: String
    var systemImage: String?
    var role: ButtonRole?
    /// Tooltip text; the shortcut is appended. Defaults to the title.
    var help: String?
    let shortcuts: [KeyboardShortcut]
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil, help: String? = nil,
         shortcuts: KeyboardShortcut..., action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.help = help
        self.shortcuts = shortcuts
        self.action = action
    }

    private var hinting: Bool { ShortcutHints.shared.visible }

    var body: some View {
        Button(role: role, action: action) {
            if let systemImage {
                Label { Text(underlinedTitle) } icon: { Image(systemName: systemImage) }
            } else {
                Text(underlinedTitle)
            }
        }
        .keyboardShortcut(shortcuts[0])
        .help(Self.tooltip(help ?? title, shortcuts[0]))
        .modifier(ExtraShortcuts(title: title, shortcuts: Array(shortcuts.dropFirst()), action: action))
        .overlay(alignment: .topTrailing) {
            if hinting {
                Text(shortcuts[0].symbols)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.background, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5)))
                    .foregroundStyle(.primary)
                    .opacity(isEnabled ? 1 : 0.4)
                    .fixedSize()
                    .offset(x: 8, y: -9)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityIdentifier("shortcutHint")
            }
        }
        .animation(.easeOut(duration: 0.12), value: hinting)
    }

    static func tooltip(_ text: String, _ shortcut: KeyboardShortcut) -> String { "\(text)  \(shortcut.symbols)" }

    private var underlinedTitle: AttributedString {
        hinting ? Self.underlined(title, shortcuts) : AttributedString(title)
    }

    /// The title with the first letter shortcut's letter underlined, when the title contains it.
    static func underlined(_ title: String, _ shortcuts: [KeyboardShortcut]) -> AttributedString {
        var text = AttributedString(title)
        guard let letter = shortcuts.first(where: { $0.key.character.isLetter })?.key.character,
              let range = text.range(of: String(letter), options: .caseInsensitive) else { return text }
        text[range].underlineStyle = .single
        return text
    }
}

/// Extra shortcuts need a button each; invisible ones still receive them. Only added when there are any:
/// in a toolbar, even an empty background of buttons makes SwiftUI open a stack of extra windows.
private struct ExtraShortcuts: ViewModifier {
    let title: String
    let shortcuts: [KeyboardShortcut]
    let action: () -> Void

    func body(content: Content) -> some View {
        if shortcuts.isEmpty {
            content
        } else {
            content.background {
                ForEach(shortcuts, id: \.symbols) { shortcut in
                    Button(title, action: action).keyboardShortcut(shortcut)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
            }
        }
    }
}
