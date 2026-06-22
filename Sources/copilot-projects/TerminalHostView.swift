import SwiftUI
import SwiftTerm

/// Mounts an already-created SwiftTerm view. `makeNSView` returns the retained
/// instance so the shell + scrollback survive project switches and re-mounts.
/// When `isActive` becomes true the pane grabs keyboard focus (retrying until the
/// view is actually in a window), so switching projects/tabs lands focus on the
/// selected terminal.
struct TerminalHostView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView
    var isActive: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var didFocus = false
        var wasActive = false
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        let coord = context.coordinator
        if isActive {
            // On becoming visible, force a full repaint. A pane that received output
            // while hidden (opacity 0 in the ZStack) can come back blank: AppKit may
            // drop its backing store while occluded, and nothing re-triggers draw()
            // on reveal. SwiftTerm's draw() repaints the visible buffer for the dirty
            // rect, so invalidating the whole view (needsDisplay = true) restores it.
            // Re-assert on the next runloop tick to catch the post-layout state.
            if !coord.wasActive {
                nsView.needsDisplay = true
                DispatchQueue.main.async { [weak nsView] in nsView?.needsDisplay = true }
            }
            coord.wasActive = true
            if !coord.didFocus {
                Self.focusWhenInWindow(nsView, coordinator: coord, attemptsLeft: 8)
            }
        } else {
            coord.wasActive = false
            coord.didFocus = false
        }
    }

    private static func focusWhenInWindow(_ view: NSView, coordinator: Coordinator, attemptsLeft: Int) {
        guard !coordinator.didFocus else { return }
        if let window = view.window {
            coordinator.didFocus = true
            window.makeFirstResponder(view)
            // Now that the pane is actually on-screen, force a repaint — covers the
            // case where it was revealed before being in a window (so the earlier
            // needsDisplay was a no-op and it would otherwise show blank).
            view.needsDisplay = true
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.async {
            focusWhenInWindow(view, coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
        }
    }
}
