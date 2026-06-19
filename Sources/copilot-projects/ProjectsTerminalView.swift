import AppKit
import SwiftTerm

/// A `LocalProcessTerminalView` that makes the scroll wheel work inside
/// full-screen TUIs.
///
/// SwiftTerm's stock `scrollWheel` only ever scrolls its *own* scrollback
/// buffer, which is empty while an app owns the alternate screen (copilot, vim,
/// less, …) — so the wheel looks dead and the app never sees it. SwiftTerm's
/// `scrollWheel` is `public` (not `open`), so we can't override it; instead a
/// local event monitor (see `AppDelegate`) calls `forwardScroll` first.
///
/// We mirror what real terminals do:
///  1. App has mouse reporting on → translate the wheel into mouse wheel
///     button events (button 4/5).
///  2. App is on the alternate screen without mouse reporting → "alternate
///     scroll": send cursor up/down keys so pagers/TUIs scroll.
///  3. Otherwise (normal shell) → let SwiftTerm scroll its own scrollback.
final class ProjectsTerminalView: LocalProcessTerminalView {
    private var scrollAccum: CGFloat = 0

    /// Returns true if the wheel event was handled (and so should be consumed).
    /// Returns false to let SwiftTerm scroll its own buffer. `agentLive` is true
    /// when a copilot agent owns this session: such a session is a mouse-reporting
    /// TUI even when SwiftTerm's mode looks off after a dtach-resume desync, so the
    /// wheel is forwarded as mouse events regardless.
    func forwardScroll(_ event: NSEvent, agentLive: Bool) -> Bool {
        guard let terminal = terminal else { return false }

        // Accumulate fractional/precise deltas so a single trackpad flick (dozens
        // of tiny events) doesn't fire dozens of steps. Positive = up.
        let cellH = bounds.height > 0 ? bounds.height / CGFloat(max(terminal.rows, 1)) : 18
        let lines = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / max(cellH, 1)
            : event.scrollingDeltaY
        guard lines != 0 else { return false }

        if (lines > 0) != (scrollAccum > 0) { scrollAccum = 0 }
        scrollAccum += lines
        let steps = Int(scrollAccum)
        guard steps != 0 else { return true }   // consumed; still accumulating
        scrollAccum -= CGFloat(steps)

        let up = steps > 0
        let count = min(abs(steps), 8)

        if agentLive || (allowMouseReporting && terminal.mouseMode != .off) {
            // 1. App reads the mouse (or is a live agent TUI) → send wheel buttons.
            let mods = event.modifierFlags
            let flags = terminal.encodeButton(
                button: up ? 4 : 5, release: false,
                shift: mods.contains(.shift), meta: mods.contains(.option), control: mods.contains(.control))
            let pos = gridPosition(for: event)
            for _ in 0 ..< count { terminal.sendEvent(buttonFlags: flags, x: pos.col, y: pos.row) }
            return true
        }

        if terminal.isCurrentBufferAlternate {
            // 2. Alt-screen app without mouse reporting → alternate-scroll: send
            //    cursor up/down keys (application-cursor aware).
            let seq: [UInt8] = up
                ? (terminal.applicationCursor ? [0x1b, 0x4f, 0x41] : [0x1b, 0x5b, 0x41])   // ESC O A / ESC [ A
                : (terminal.applicationCursor ? [0x1b, 0x4f, 0x42] : [0x1b, 0x5b, 0x42])   // ESC O B / ESC [ B
            for _ in 0 ..< count { send(seq) }
            return true
        }

        // 3. Normal shell buffer → scroll SwiftTerm's own scrollback directly and
        //    consume the event. (Returning the event for SwiftTerm's scrollWheel
        //    to handle lets SwiftUI swallow it first, so scrolling looked dead.)
        guard canScroll else { return false }
        if up { scrollUp(lines: count) } else { scrollDown(lines: count) }
        return true
    }

    /// Approximate on-screen cell under the pointer. SwiftTerm's exact hit-test
    /// and cell metrics are internal, so we derive cell size from the view bounds
    /// and the terminal's row/column count — fine for wheel events.
    private func gridPosition(for event: NSEvent) -> (col: Int, row: Int) {
        guard let terminal = terminal, bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let p = convert(event.locationInWindow, from: nil)
        let cellW = bounds.width / CGFloat(terminal.cols)
        let cellH = bounds.height / CGFloat(terminal.rows)
        let col = min(max(0, Int(p.x / max(cellW, 1))), terminal.cols - 1)
        let row = min(max(0, Int((bounds.height - p.y) / max(cellH, 1))), terminal.rows - 1)
        return (col, row)
    }

    /// True when the pointer for `event` is over this terminal view. Uses
    /// `hitTest` (robust against the SwiftUI/representable nesting) rather than
    /// manual bounds math.
    func containsPointer(for event: NSEvent) -> Bool {
        guard let win = event.window ?? window,
              let hit = win.contentView?.hitTest(event.locationInWindow) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }
}
