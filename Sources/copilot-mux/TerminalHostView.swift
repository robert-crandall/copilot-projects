import SwiftUI
import SwiftTerm

/// Mounts an already-created SwiftTerm view. `makeNSView` returns the retained
/// instance so the shell + scrollback survive project switches and re-mounts.
/// When `isActive` first becomes true the pane grabs keyboard focus once.
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
            if !context.coordinator.didFocus, let window = nsView.window {
                window.makeFirstResponder(nsView)
                context.coordinator.didFocus = true
            }
        } else {
            context.coordinator.didFocus = false
        }
    }
}
