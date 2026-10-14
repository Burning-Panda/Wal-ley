import SwiftUI
import AppKit

/// Keeps the app to one window. Every view shares one `DatabaseManager`, so a second window would mirror the
/// first, sheets included. macOS can still bring extras back from saved window state; they close on arrival.
struct SingleWindow: NSViewRepresentable {
    @MainActor private static weak var primary: NSWindow?

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if let primary = SingleWindow.primary, primary !== window, primary.isVisible {
                // Closing while SwiftUI is still attaching the window is unsafe; wait a turn.
                DispatchQueue.main.async { window.close() }
            } else {
                SingleWindow.primary = window
            }
        }
    }
}
