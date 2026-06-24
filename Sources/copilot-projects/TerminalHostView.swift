import SwiftUI
import SwiftTerm

/// Mounts an already-created SwiftTerm view. Only the active session's pane is
/// mounted (see `ProjectTerminalsView`), and `makeNSView` returns the retained
/// instance, so the shell + scrollback survive unmount/remount across tab and
/// project switches. On mount the pane grabs keyboard focus (retrying until it is
/// actually in a window) and gets one conservative full-bounds repaint.
struct TerminalHostView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var didSettle = false
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        let coord = context.coordinator
        guard !coord.didSettle else { return }
        Self.settleWhenReady(nsView, coordinator: coord, attemptsLeft: 8)
    }

    /// Once the freshly-mounted pane is in a window with a real size: focus it and
    /// force a full-bounds repaint. AppKit already redraws a newly-inserted view in
    /// full, but the mount can land before final layout, so this re-asserts after
    /// layout. It runs async and only when in-window with non-empty bounds —
    /// avoiding the "drew blank during SwiftUI reconciliation" failure mode of a
    /// synchronous early draw.
    private static func settleWhenReady(_ view: LocalProcessTerminalView, coordinator: Coordinator, attemptsLeft: Int) {
        guard let window = view.window, !view.bounds.isEmpty else {
            guard attemptsLeft > 0 else { return }
            DispatchQueue.main.async {
                settleWhenReady(view, coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        coordinator.didSettle = true
        window.makeFirstResponder(view)
        view.layoutSubtreeIfNeeded()
        view.terminal.updateFullScreen()
        view.setNeedsDisplay(view.bounds)
    }
}
