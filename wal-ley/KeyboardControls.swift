import SwiftUI
import AppKit

/// Pop-up that takes part in Tab navigation even when the system's full keyboard access is off. Space, return
/// and the down arrow open it; the menu then takes the arrows and return as usual.
final class TabbablePopUp: NSPopUpButton {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { performClick(nil) } else { super.keyDown(with: event) }
    }
}

/// A pop-up menu: a plain list with one selected item, or (`title` set) a pull-down of checkable actions.
struct KeyPopUp: NSViewRepresentable {
    struct Item: Equatable {
        var title: String
        var checked = false
    }

    var items: [Item]
    /// Index of the selected item for a plain pop-up.
    var selected = 0
    /// Makes this a pull-down showing this title (and `symbol`) instead of the selection.
    var title: String?
    var symbol: String?
    var onSelect: (Int) -> Void

    func makeNSView(context: Context) -> TabbablePopUp {
        let button = TabbablePopUp(frame: .zero, pullsDown: title != nil)
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: TabbablePopUp, context: Context) {
        context.coordinator.parent = self
        button.removeAllItems()
        if let title {
            button.addItem(withTitle: title)
            button.item(at: 0)?.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        }
        for item in items {
            button.addItem(withTitle: item.title)
            button.lastItem?.state = item.checked ? .on : .off
        }
        if title == nil, items.indices.contains(selected) { button.selectItem(at: selected) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: KeyPopUp
        init(_ parent: KeyPopUp) { self.parent = parent }

        @objc func picked(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem - (parent.title == nil ? 0 : 1)
            if parent.items.indices.contains(index) { parent.onSelect(index) }
        }
    }
}

/// Segmented control that Tab reaches; left and right arrows move between segments.
final class TabbableSegmented: NSSegmentedControl {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123 where selectedSegment > 0: move(to: selectedSegment - 1)
        case 124 where selectedSegment < segmentCount - 1: move(to: selectedSegment + 1)
        default: super.keyDown(with: event)
        }
    }

    private func move(to segment: Int) {
        selectedSegment = segment
        sendAction(action, to: target)
    }
}

struct KeySegmented: NSViewRepresentable {
    let titles: [String]
    @Binding var selected: Int

    func makeNSView(context: Context) -> TabbableSegmented {
        let control = TabbableSegmented(labels: titles, trackingMode: .selectOne,
                                        target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        return control
    }

    func updateNSView(_ control: TabbableSegmented, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = selected
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: KeySegmented
        init(_ parent: KeySegmented) { self.parent = parent }

        @objc func changed(_ sender: NSSegmentedControl) { parent.selected = sender.selectedSegment }
    }
}

extension View {
    /// A Tab stop that runs `action` on space or return.
    func keyActivated(tabStop: Bool = true, _ action: @escaping () -> Void) -> some View {
        focusable(tabStop)
            .onKeyPress(.space) { action(); return .handled }
            .onKeyPress(.return) { action(); return .handled }
    }
}
