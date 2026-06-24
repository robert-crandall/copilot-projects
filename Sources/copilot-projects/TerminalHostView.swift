import SwiftUI
import SwiftTerm

/// Mounts an already-created SwiftTerm view. `makeNSView` returns the retained
/// instance so the shell + scrollback survive project switches and re-mounts. All
/// panes stay mounted (hidden with opacity); when `isActive` flips true the pane
/// grabs keyboard focus (retrying until it is actually in a window) and gets one
/// full-bounds repaint. SwiftTerm's partial-redraw optimization is disabled (see
/// TerminalController), so that single invalidation repaints every row — fixing
/// the stale chrome a revealed opacity-0 pane used to show — and later output
/// keeps the pane whole.
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
            if !coord.wasActive {
                coord.wasActive = true
                coord.didFocus = false
                Self.settleWhenInWindow(nsView, coordinator: coord, attemptsLeft: 8)
            }
        } else {
            coord.wasActive = false
            coord.didFocus = false
        }
    }

    /// Once the now-visible pane is in a window with a real size: focus it and force
    /// a full-bounds repaint. Async + in-window + non-empty-bounds guards avoid the
    /// "drew blank during SwiftUI reconciliation / before layout" failure mode of a
    /// synchronous early draw.
    private static func settleWhenInWindow(_ view: LocalProcessTerminalView, coordinator: Coordinator, attemptsLeft: Int) {
        guard let window = view.window, !view.bounds.isEmpty else {
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.async {
                settleWhenInWindow(view, coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        if !coordinator.didFocus {
            coordinator.didFocus = true
            window.makeFirstResponder(view)
        }
        view.layoutSubtreeIfNeeded()
        view.terminal.updateFullScreen()
        view.setNeedsDisplay(view.bounds)
    }
}
