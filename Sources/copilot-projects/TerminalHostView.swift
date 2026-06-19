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
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        if isActive {
            if !context.coordinator.didFocus {
                Self.focusWhenInWindow(nsView, coordinator: context.coordinator, attemptsLeft: 8)
            }
        } else {
            context.coordinator.didFocus = false
        }
    }

    private static func focusWhenInWindow(_ view: NSView, coordinator: Coordinator, attemptsLeft: Int) {
        guard !coordinator.didFocus else { return }
        if let window = view.window {
            coordinator.didFocus = true
            window.makeFirstResponder(view)
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.async {
            focusWhenInWindow(view, coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
        }
    }
}
