import AppKit
import SwiftTerm

/// A `LocalProcessTerminalView` that knows how to forward the scroll wheel to the
/// child program.
///
/// SwiftTerm's stock `scrollWheel` always scrolls its *own* scrollback buffer.
/// That buffer is empty while an app owns the alternate screen (copilot, vim,
/// less, …), so the wheel appears dead and the app never sees it. SwiftTerm's
/// `scrollWheel` is `public` (not `open`), so we can't override it; instead a
/// local event monitor (see `AppDelegate`) calls `forwardScroll` before the view
/// handles the event. When the program has mouse reporting on we translate the
/// wheel into mouse wheel button events and consume it; otherwise we let
/// SwiftTerm fall back to its native scrollback.
final class MuxTerminalView: LocalProcessTerminalView {
    /// Returns true if the wheel event was forwarded to the child program (and so
    /// should be consumed). Returns false to let SwiftTerm scroll its own buffer.
    func forwardScroll(_ event: NSEvent) -> Bool {
        guard let terminal = terminal, allowMouseReporting, terminal.mouseMode != .off
        else { return false }

        // Translate this event into a signed number of whole line-steps,
        // accumulating fractional/precise deltas so a single trackpad flick
        // (dozens of tiny events) doesn't fire dozens of wheel presses at once.
        // Positive = wheel up (button 4), matching SwiftTerm's own sign convention.
        let cellH = bounds.height > 0 ? bounds.height / CGFloat(max(terminal.rows, 1)) : 18
        let lines = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / max(cellH, 1)   // points → lines
            : event.scrollingDeltaY                    // already in lines
        guard lines != 0 else { return false }

        if (lines > 0) != (scrollAccum > 0) { scrollAccum = 0 }   // direction flip
        scrollAccum += lines
        let steps = Int(scrollAccum)                   // whole lines ready to emit
        guard steps != 0 else { return true }          // consumed; still accumulating
        scrollAccum -= CGFloat(steps)

        let mods = event.modifierFlags
        let flags = terminal.encodeButton(
            button: steps > 0 ? 4 : 5,
            release: false,
            shift: mods.contains(.shift),
            meta: mods.contains(.option),
            control: mods.contains(.control))

        let pos = gridPosition(for: event)
        for _ in 0 ..< min(abs(steps), 10) {           // cap pathological bursts
            terminal.sendEvent(buttonFlags: flags, x: pos.col, y: pos.row)
        }
        return true
    }

    private var scrollAccum: CGFloat = 0

    /// Approximate on-screen cell under the pointer. SwiftTerm's exact hit-test
    /// and cell metrics are internal, so we derive cell size from the view
    /// bounds and the terminal's row/column count. TUIs only use this loosely
    /// for wheel events, so the approximation is fine.
    private func gridPosition(for event: NSEvent) -> (col: Int, row: Int) {
        guard let terminal = terminal, bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let p = convert(event.locationInWindow, from: nil)
        let cellW = bounds.width / CGFloat(terminal.cols)
        let cellH = bounds.height / CGFloat(terminal.rows)
        let col = min(max(0, Int(p.x / max(cellW, 1))), terminal.cols - 1)
        // The view is not flipped (origin bottom-left); row 0 is the top.
        let row = min(max(0, Int((bounds.height - p.y) / max(cellH, 1))), terminal.rows - 1)
        return (col, row)
    }

    /// True when the pointer for `event` is inside this terminal view.
    func containsPointer(for event: NSEvent) -> Bool {
        guard let window = window, event.window === window else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }
}
