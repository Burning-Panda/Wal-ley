import SwiftUI
import AppKit

/// Single-line text field that keeps exactly what was typed: no smart quotes, dashes, replacements or spelling fixes.
struct PlainTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var monospaced = false
    /// Off for cells in a grid: no bezel or background, just the text.
    var bordered = true
    var focusOnAppear = false
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        if bordered {
            field.bezelStyle = .roundedBezel
        } else {
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
        }
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if focusOnAppear {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PlainTextField
        init(_ parent: PlainTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.smartInsertDeleteEnabled = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}
