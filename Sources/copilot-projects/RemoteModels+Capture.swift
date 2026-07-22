import Foundation
import CopilotProjectsProtocol

extension RemoteTerminalScreen {
    static func captureVisible(
        sessionId: String,
        cols: Int,
        rows: Int,
        lineAt: (Int) -> String?
    ) -> RemoteTerminalScreen {
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0 ..< rows {
            lines.append(RemoteKittyGraphics.sanitizeLine(
                (lineAt(row) ?? "").replacingOccurrences(of: "\u{0}", with: " ")
            ))
        }
        return RemoteTerminalScreen(
            sessionId: sessionId,
            cols: cols,
            rows: rows,
            scrollMode: .terminal,
            historyStartLine: 0,
            firstLine: 0,
            liveTopLine: 0,
            reset: true,
            lines: lines
        )
    }

    static func captureHistory(
        sessionId: String,
        cols: Int,
        rows: Int,
        absoluteStart: Int,
        scanRows: Int,
        maximumRows: Int,
        afterLine: Int?,
        lineExists: (Int) -> Bool,
        lineAt: (Int) -> String?
    ) -> RemoteTerminalScreen {
        var lowerBound = absoluteStart
        var upperBound = absoluteStart + max(scanRows, rows)
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if lineExists(midpoint) {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        let absoluteEnd = lowerBound
        let historyStart = max(absoluteStart, absoluteEnd - maximumRows)
        let firstLine: Int
        let reset: Bool
        if let afterLine, afterLine >= historyStart, afterLine <= absoluteEnd {
            firstLine = max(historyStart, afterLine - rows)
            reset = false
        } else {
            firstLine = historyStart
            reset = true
        }

        var lines: [String] = []
        lines.reserveCapacity(max(0, absoluteEnd - firstLine))
        for line in firstLine ..< absoluteEnd {
            guard let value = lineAt(line) else { break }
            lines.append(RemoteKittyGraphics.sanitizeLine(
                value.replacingOccurrences(of: "\u{0}", with: " ")
            ))
        }
        return RemoteTerminalScreen(
            sessionId: sessionId,
            cols: cols,
            rows: rows,
            scrollMode: .history,
            historyStartLine: historyStart,
            firstLine: firstLine,
            liveTopLine: max(historyStart, absoluteEnd - rows),
            reset: reset,
            lines: lines
        )
    }

    /// Attaches `images` (or clears them) without altering any other field —
    /// used to attach freshly recomputed Kitty placements to an already-captured
    /// screen so live/history text and scroll semantics are untouched. Callers
    /// scanning the full retained history should always pass a present array
    /// (`[]` included when nothing was found), never `nil` — see
    /// `RemoteTerminalScreen.images`'s doc comment for why that distinction
    /// matters to a client.
    func withImages(_ images: [RemoteTerminalImagePlacement]?) -> RemoteTerminalScreen {
        RemoteTerminalScreen(
            sessionId: sessionId,
            cols: cols,
            rows: rows,
            scrollMode: scrollMode,
            historyStartLine: historyStartLine,
            firstLine: firstLine,
            liveTopLine: liveTopLine,
            reset: reset,
            lines: lines,
            images: images
        )
    }
}
