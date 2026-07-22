import Foundation
import SwiftTerm
import CopilotProjectsProtocol
import ImageIO
import UniformTypeIdentifiers

// MARK: - Bounds

/// A single unterminated APC frame (control data + one chunk's payload) is
/// bounded well past the ~4 KiB raw chunks real encoders emit, so a runaway
/// non-terminated sequence can't grow memory unbounded.
private let remoteKittyMaxRawFrameBytes = 96 * 1_024
/// Base64 accumulated across `m=1` continuation chunks for a single in-flight
/// image, bounded comfortably above the base64 size of `remoteKittyMaxDecodedImageBytes`.
private let remoteKittyMaxAccumulatedBase64Bytes = 8 * 1_024 * 1_024
/// Decoded PNG bytes retained per image.
private let remoteKittyMaxDecodedImageBytes = 5 * 1_024 * 1_024
private let remoteKittyMaxImageDimension = 4_096
private let remoteKittyMaxImagePixels = 16_000_000
/// Total bytes retained per-*session* (per `RemoteKittyImageCapture` instance)
/// across all its (id, version) entries in the grace cache. Deliberately much
/// smaller than `RemoteKittyImageCaptureBudget`'s process-wide bound below —
/// this only guards a single busy terminal, while the shared budget guards the
/// whole process across every open terminal.
private let remoteKittyMaxTotalRetainedBytes = 8 * 1_024 * 1_024
/// Entry count cap for the per-session grace cache (independent of the byte
/// cap, so a burst of tiny images can't accumulate unboundedly either), also
/// deliberately smaller than the process-wide entry cap.
private let remoteKittyMaxRetainedEntries = 16
/// Size above which a discarded/finalized transient buffer (`rawFrame` or
/// `pendingBase64`) has its underlying storage actually deallocated
/// (`keepingCapacity: false`) rather than kept around for reuse. Below this,
/// `keepingCapacity: true` avoids paying for a realloc on every tiny/common
/// frame. A buffer that grew past this before being discarded proves it can
/// grow large, so its capacity must be given back — otherwise N busy
/// terminals could each pin megabytes of buffer capacity even though the
/// shared pending-byte *count* budget below is enforced.
private let remoteKittyLargeBufferReleaseThreshold = 64 * 1_024
/// Hard cap on placements emitted by a single scan, so a pathological grid
/// (e.g. hundreds of disjoint single-cell placeholder fragments) can't make a
/// scan (or its JSON payload) unbounded. Connected-component work stops the
/// moment this many placements have been found, rather than discovering every
/// component and truncating only the final list.
private let remoteKittyMaxEmittedPlacements = 64

// MARK: - Placeholder grapheme decoding (pure, SwiftTerm-independent)

/// Decodes the Kitty Unicode-placeholder scheme (`U+10EEEE` + foreground color
/// carrying the low 24 bits of the image id) directly from plain grapheme +
/// color inputs, so this logic is testable without any SwiftTerm dependency and
/// matches SwiftTerm's own (private) `KittyPlaceholderDecoder.colorToId` byte
/// order: `red | green << 8 | blue << 16`.
enum RemoteKittyPlaceholderCell {
    static let baseScalar: UInt32 = 0x10EEEE

    /// Returns the low-24-bit image id encoded in `character`'s foreground color,
    /// or `nil` if `character` isn't a standard placeholder grapheme (first
    /// scalar isn't `U+10EEEE`) or its foreground isn't a truecolor value, or the
    /// decoded id is out of the `1...0xFFFFFF` range our capture ever assigns.
    static func decodeImageId(
        character: Character,
        foreground: (red: UInt8, green: UInt8, blue: UInt8)?
    ) -> UInt32? {
        guard let foreground else { return nil }
        guard let first = character.unicodeScalars.first, first.value == baseScalar else {
            return nil
        }
        let imageId = UInt32(foreground.red)
            | (UInt32(foreground.green) << 8)
            | (UInt32(foreground.blue) << 16)
        guard imageId >= 1, imageId <= 0xFFFFFF else { return nil }
        return imageId
    }
}

/// Text-level sanitization shared by both live and history line capture: a raw
/// placeholder grapheme is meaningless (and potentially confusing) as remote
/// text, so it collapses to a single space, preserving the cell/column count.
enum RemoteKittyGraphics {
    static func sanitizeLine(_ line: String) -> String {
        guard line.unicodeScalars.contains(where: { $0.value == RemoteKittyPlaceholderCell.baseScalar }) else {
            return line
        }
        var result = ""
        result.reserveCapacity(line.count)
        for character in line {
            if character.unicodeScalars.first?.value == RemoteKittyPlaceholderCell.baseScalar {
                result.append(" ")
            } else {
                result.append(character)
            }
        }
        return result
    }
}

// MARK: - Grid scanning -> placements (pure, SwiftTerm-independent)

/// One decoded placeholder grid cell, in the coordinate space the caller used
/// (viewport row ids for a live screen, scroll-invariant absolute row ids for a
/// history screen).
struct RemoteKittyGridCell: Equatable {
    let lineId: Int
    let col: Int
    let imageId: UInt32
}

enum RemoteKittyPlacementScanner {
    private struct Coordinate: Hashable {
        let lineId: Int
        let col: Int
    }

    /// One fully flood-filled connected component, still tagged with its
    /// bounding box in the caller's line-id coordinate space (not yet
    /// translated relative to `firstLine`) so priority classification and
    /// bottom-first sorting can both work directly off `minLine`.
    private struct Component {
        let imageId: UInt32
        let version: UInt64
        let minLine: Int
        let maxLine: Int
        let minCol: Int
        let maxCol: Int
    }

    /// Groups `cells` by image id, splits each id's cells into 4-neighbor
    /// connected components (so two disjoint placements sharing an id never
    /// merge into one bounding box), and emits one placement per component —
    /// only for ids with a `currentVersion`, i.e. a still-retained capture.
    /// `firstLine` converts the caller's absolute/viewport line ids into rows
    /// relative to the emitted screen. Sorted deterministically by
    /// (line, column, imageId) so repeated scans of the same grid are stable.
    ///
    /// Emits at most `remoteKittyMaxEmittedPlacements` placements, chosen in
    /// two priority tiers so a producer scanning the *entire* retained
    /// history can never let old/stale history starve the current/new
    /// content a client actually asked for:
    ///
    /// 1. Every component that intersects `priorityLineRange` (any one of its
    ///    cells has a `lineId` inside that range) — i.e. the screen window a
    ///    client is actually looking at right now (the whole viewport for a
    ///    live scan, or just the emitted incremental text window for a
    ///    history scan). These are always considered first, sorted
    ///    deterministically ascending by `(minLine, minCol, imageId)`, and
    ///    truncated to the cap if even this tier alone exceeds it.
    /// 2. Whatever cap budget remains (if any) is spent on every other,
    ///    non-intersecting component — the rest of the retained history —
    ///    sorted deterministically newest/bottom-first (descending
    ///    `minLine`, since a larger scroll-invariant row id is always more
    ///    recent), so among old history that doesn't fit, the *most* recent
    ///    of it is kept over the oldest.
    ///
    /// Either way a component is always emitted whole or not at all — the
    /// cap only ever drops entire components, never truncates one — and the
    /// final returned order is always the same (line, column, imageId) sort
    /// regardless of which tier a placement was selected from.
    static func scan(
        cells: [RemoteKittyGridCell],
        firstLine: Int,
        priorityLineRange: Range<Int>,
        currentVersion: (UInt32) -> UInt64?
    ) -> [RemoteTerminalImagePlacement] {
        guard !cells.isEmpty else { return [] }

        var byImage: [UInt32: Set<Coordinate>] = [:]
        for cell in cells {
            byImage[cell.imageId, default: []].insert(Coordinate(lineId: cell.lineId, col: cell.col))
        }

        var priorityComponents: [Component] = []
        var otherComponents: [Component] = []

        for imageId in byImage.keys.sorted() {
            guard let version = currentVersion(imageId), let coordinates = byImage[imageId] else { continue }
            // Seeded deterministically (smallest `(lineId, col)` first) —
            // sorted once per image id up front, rather than repeatedly
            // scanning the shrinking `remaining` set for its minimum before
            // every single component. That repeated-`.min()` approach made
            // discovery cost O(component count) *per component*, which for a
            // checkerboard grid (every marked cell its own disjoint
            // single-cell component, so component count == cell count) is
            // O(n^2) in total cells for that image id. Sorting once is
            // O(n log n); `remaining` still gives O(1) flood-fill
            // neighbor membership/removal, and each sorted seed is visited or
            // skipped (already claimed by an earlier component) exactly
            // once, so the whole seed walk is O(n) on top of the sort.
            // Component membership, priority-tier classification, and the
            // final deterministic sort/cap below are all unchanged — the
            // *set* of coordinates flood-filled into each component never
            // depends on which of its members was chosen as the seed.
            var remaining = coordinates
            let sortedSeeds = coordinates.sorted { ($0.lineId, $0.col) < ($1.lineId, $1.col) }
            for start in sortedSeeds {
                guard remaining.contains(start) else { continue }
                remaining.remove(start)
                var component: [Coordinate] = [start]
                var frontier = [start]
                var intersectsPriority = priorityLineRange.contains(start.lineId)
                while let coordinate = frontier.popLast() {
                    let neighbors = [
                        Coordinate(lineId: coordinate.lineId - 1, col: coordinate.col),
                        Coordinate(lineId: coordinate.lineId + 1, col: coordinate.col),
                        Coordinate(lineId: coordinate.lineId, col: coordinate.col - 1),
                        Coordinate(lineId: coordinate.lineId, col: coordinate.col + 1),
                    ]
                    for neighbor in neighbors where remaining.contains(neighbor) {
                        remaining.remove(neighbor)
                        component.append(neighbor)
                        frontier.append(neighbor)
                        if priorityLineRange.contains(neighbor.lineId) { intersectsPriority = true }
                    }
                }
                let lineIds = component.map(\.lineId)
                let cols = component.map(\.col)
                guard let minLine = lineIds.min(), let maxLine = lineIds.max(),
                      let minCol = cols.min(), let maxCol = cols.max() else { continue }
                let entry = Component(
                    imageId: imageId, version: version,
                    minLine: minLine, maxLine: maxLine, minCol: minCol, maxCol: maxCol
                )
                if intersectsPriority {
                    priorityComponents.append(entry)
                } else {
                    otherComponents.append(entry)
                }
            }
        }

        priorityComponents.sort {
            if $0.minLine != $1.minLine { return $0.minLine < $1.minLine }
            if $0.minCol != $1.minCol { return $0.minCol < $1.minCol }
            return $0.imageId < $1.imageId
        }
        otherComponents.sort {
            if $0.minLine != $1.minLine { return $0.minLine > $1.minLine }
            if $0.minCol != $1.minCol { return $0.minCol < $1.minCol }
            return $0.imageId < $1.imageId
        }

        var selected = Array(priorityComponents.prefix(remoteKittyMaxEmittedPlacements))
        let remainingBudget = remoteKittyMaxEmittedPlacements - selected.count
        if remainingBudget > 0 {
            selected.append(contentsOf: otherComponents.prefix(remainingBudget))
        }

        let placements = selected.map {
            RemoteTerminalImagePlacement(
                imageId: $0.imageId,
                contentVersion: $0.version,
                line: $0.minLine - firstLine,
                column: $0.minCol,
                rows: $0.maxLine - $0.minLine + 1,
                columns: $0.maxCol - $0.minCol + 1
            )
        }
        return placements.sorted {
            if $0.line != $1.line { return $0.line < $1.line }
            if $0.column != $1.column { return $0.column < $1.column }
            return $0.imageId < $1.imageId
        }
    }

    /// Adapter over public SwiftTerm grid accessors only (never Kitty-specific
    /// internal parser state): scans each supplied `(lineID, BufferLine)` for
    /// standard placeholder graphemes using `terminal.getCharacter(for:)` (which
    /// resolves the full multi-scalar grapheme SwiftTerm stored for the cell)
    /// and the cell's foreground color.
    static func gridCells(
        from lines: [(lineId: Int, line: BufferLine)],
        terminal: Terminal
    ) -> [RemoteKittyGridCell] {
        var cells: [RemoteKittyGridCell] = []
        for (lineId, line) in lines {
            for col in 0 ..< line.count {
                let cellData = line[col]
                guard case .trueColor(let red, let green, let blue) = cellData.attribute.fg else {
                    continue
                }
                let character = terminal.getCharacter(for: cellData)
                guard let imageId = RemoteKittyPlaceholderCell.decodeImageId(
                    character: character,
                    foreground: (red, green, blue)
                ) else { continue }
                cells.append(RemoteKittyGridCell(lineId: lineId, col: col, imageId: imageId))
            }
        }
        return cells
    }
}

// MARK: - Kitty graphics APC capture (bounded, fail-closed)

/// Captures the exact Copilot Kitty graphics subset (7-bit APC
/// `ESC _ G ... ESC \`, direct transmission, `f=100` PNG, `U=1`, explicit
/// 1-in-0xFFFFFF image ids, `m=1` continuation chunks) from raw terminal output
/// bytes, independent of SwiftTerm's own (private, display-only) Kitty state.
///
/// One instance is owned per terminal session (`ProjectsTerminalView`) — never a
/// shared/global identity-bearing store — and every mutating access happens on
/// the main actor, so there is no cross-session identity confusion and no data
/// race with the terminal's own main-actor-only rendering. Retained bytes are
/// additionally accounted against a process-wide `RemoteKittyImageCaptureBudget`
/// (also main-actor-only), so no fixed number of open terminals can be relied
/// upon to keep total memory bounded — the shared budget enforces that across
/// every instance regardless of how many terminals are open.
///
/// Anything outside the supported subset (unsupported compression/transmission
/// medium/format/id, malformed or oversized frames) is silently ignored: the
/// capture never throws, never grows without bound, and a later well-formed
/// frame always parses correctly because every overflow discards and
/// resynchronizes rather than wedging the scanner's state.
///
/// Every other terminal string type that can carry its own `ESC` bytes — OSC
/// (`ESC ]`), DCS (`ESC P`), and PM (`ESC ^`) — is also tracked (its payload
/// entirely ignored) up to its own real terminator (BEL or ST for OSC, ST
/// only for DCS/PM), so a `ESC _ G` byte sequence that merely happens to
/// appear *inside* one of their payloads (e.g. inside base64-ish OSC title
/// data) can never be misparsed as the start of our own Kitty APC: the
/// scanner only ever looks for a fresh APC from `.ground`, never mid-string.
@MainActor
final class RemoteKittyImageCapture {
    private struct StoredKey: Hashable {
        let imageId: UInt32
        let version: UInt64
    }

    private enum ScanState {
        case ground
        case sawEsc
        case apcAwaitingMarker
        case apcAccumulating
        case apcAccumulatingEsc
        case apcSkipping
        case apcSkippingEsc
        /// Inside an OSC (`ESC ]`), DCS (`ESC P`), or PM (`ESC ^`) string
        /// whose payload is being ignored outright — never parsed as our own
        /// Kitty subset, and never able to nest one. `allowsBEL` is true only
        /// for OSC, whose payload may additionally terminate on a bare BEL
        /// (`0x07`) rather than requiring the full ST (`ESC \`) every other
        /// string type here requires.
        case controlStringSkipping(allowsBEL: Bool)
        /// One `ESC` seen while skipping a control string: resolves to
        /// either the real ST terminator (`\`, ending the string) or, for
        /// anything else, right back into the string body — so a byte that
        /// merely happens to look like the start of our own APC (`_`) inside
        /// someone else's string payload is never treated as one.
        case controlStringSkippingEsc(allowsBEL: Bool)
    }

    private var state: ScanState = .ground
    private var rawFrame: [UInt8] = []

    private var pendingImageId: UInt32?
    private var pendingBase64: [UInt8] = []

    // Retained (id, version) entries, oldest-first; `dataByKey`/`totalBytes` are
    // kept in lockstep and `latestVersion` tracks each id's newest still-retained
    // version so a scan can tell whether an id's data is still fetchable.
    private var order: [StoredKey] = []
    private var dataByKey: [StoredKey: Data] = [:]
    private var totalBytes = 0
    private var latestVersion: [UInt32: UInt64] = [:]

    // Ids with a currently *active* Unicode-placeholder placement — tracked
    // separately from `latestVersion`/`dataByKey` (retained PNG bytes) so the
    // two lifecycles (placement vs. data) can be deleted independently, as
    // the Kitty spec itself distinguishes: a lowercase delete (`d=i`/`d=a`)
    // only ever retires a *placement*, never the underlying transmitted
    // bytes, while an uppercase one (`d=I`/`d=A`) retires both. Before this
    // separation, `currentVersion(for:)` advertised any retained id
    // regardless of whether its placement had been deleted — a ghost: a
    // client that deleted a placement (but never re-transmitted) would keep
    // seeing it in scans of the grid indefinitely, since retained bytes
    // (kept around for the grace-retention window) were the only signal.
    // An id only ever advertises via `currentVersion(for:)` when it's both
    // active *and* still has retained data.
    private var activeImageIds: Set<UInt32> = []

    // Content versions are `(epoch << 32) | counter`: `epoch` is fixed for this
    // instance's whole lifetime and `counter` is monotonic within it, so two
    // `RemoteKittyImageCapture` instances for the same session (e.g. the first
    // recreated after a relaunch) never hand out the same version number for
    // the same image id — a client can't have a stale cached fetch URL from
    // the old instance accidentally resolve against the new one's data.
    private let epoch: UInt32
    private var nextCounter: UInt64 = 1
    private let budget: RemoteKittyImageCaptureBudget
    private let maxAccumulatedBase64Bytes: Int

    /// Bumped every time this instance's *currently advertised* availability
    /// for some image id can change — a fresh current version is retained, or
    /// a still-current version is removed (by local grace-cache eviction, an
    /// explicit Kitty delete/clear, or the process-wide budget reclaiming it
    /// via `evictForBudget`, including when triggered by a *different*
    /// capture instance entirely). A superseded (non-current) version being
    /// reclaimed never bumps this, since what a scan would currently discover
    /// hasn't changed. Exposed so a screen cache keyed on it (see
    /// `RemoteTerminalRevision`) invalidates itself exactly when a
    /// previously-advertised placement could now 404, including across
    /// sessions sharing the same process-wide budget.
    private(set) var imageAvailabilityGeneration: UInt64 = 0

    /// - Parameters:
    ///   - epoch: The high 32 bits every version handed out by this instance
    ///     carries. Defaults to a fresh random value per instance (production
    ///     behavior); tests inject a fixed value for deterministic version
    ///     assertions and to prove distinct epochs never collide.
    ///   - budget: The process-wide budget this instance's retained bytes are
    ///     accounted against. Defaults to the real shared singleton; tests
    ///     inject an isolated instance so cross-test process state can never
    ///     leak into an assertion about global bounds.
    ///   - maxAccumulatedBase64Bytes: The per-instance cap on base64 bytes
    ///     accumulated across `m=1` continuation chunks for one in-flight
    ///     transmission. Defaults to the real production bound (comfortably
    ///     above `remoteKittyMaxDecodedImageBytes`'s base64 size); tests
    ///     inject a much smaller value so an overflow test can prove the
    ///     accumulated-bytes guard specifically — via many small continuation
    ///     chunks, each individually well under both the raw-frame and
    ///     decoded-image bounds — rather than relying on a single frame large
    ///     enough to *also* trip those other, unrelated bounds first.
    init(
        epoch: UInt32 = UInt32.random(in: UInt32.min ... UInt32.max),
        budget: RemoteKittyImageCaptureBudget? = nil,
        maxAccumulatedBase64Bytes: Int = remoteKittyMaxAccumulatedBase64Bytes
    ) {
        self.epoch = epoch
        // `budget`'s default can't be spelled as `= .shared` in the parameter
        // list itself: default-argument expressions aren't evaluated in the
        // enclosing (main-actor) isolation context, so referencing a
        // main-actor-isolated static there is a Swift 6 isolation error.
        // Resolving it here, inside the (main-actor-isolated) initializer
        // body, is equivalent for every real caller.
        self.budget = budget ?? .shared
        self.maxAccumulatedBase64Bytes = maxAccumulatedBase64Bytes
    }

    /// Feeds raw terminal output bytes. Safe to call with any chunking of the
    /// underlying byte stream — the scanner carries state across calls, so a
    /// frame split across arbitrary `ingest` boundaries still parses.
    func ingest(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            process(byte)
        }
    }

    /// The newest version currently retained for `imageId`, or `nil` if that
    /// id has no active Unicode-placeholder placement, or has one but no
    /// longer has any retained data for it (e.g. reclaimed by grace-cache/
    /// budget eviction) — either way, nothing a fresh scan should discover.
    func currentVersion(for imageId: UInt32) -> UInt64? {
        guard activeImageIds.contains(imageId) else { return nil }
        return latestVersion[imageId]
    }

    /// Exposes this instance's fixed epoch (otherwise `private`) so tests can
    /// assert distinct/random epochs without duplicating the version-bit
    /// layout. Not used by any production call site.
    var epochForTesting: UInt32 { epoch }

    /// The exact PNG bytes for `(imageId, version)`, or `nil` if that exact pair
    /// isn't (or is no longer) retained.
    func imageData(imageId: UInt32, version: UInt64) -> Data? {
        dataByKey[StoredKey(imageId: imageId, version: version)]
    }

    // MARK: Byte-level APC scanning

    private func process(_ byte: UInt8) {
        // CAN (0x18) / SUB (0x1A) are wired as an "anywhere" rule in
        // SwiftTerm's own VT500 transition table — they fire from every
        // parser state and always cancel back to ground, never completing
        // whatever escape sequence or control string was in progress. Mirror
        // that here so this scanner can never wedge on a byte stream that
        // happens to contain one mid-OSC/DCS/PM-skip or mid-APC-accumulation:
        // the in-progress sequence is unconditionally discarded (not
        // completed), exactly as a real terminal would resync.
        if byte == 0x18 || byte == 0x1A {
            cancelSequence()
            return
        }
        switch state {
        case .ground:
            if byte == 0x1B { state = .sawEsc }
        case .sawEsc:
            if byte == 0x5F { // '_' — APC start
                clearRawFrame()
                state = .apcAwaitingMarker
            } else if byte == 0x1B {
                state = .sawEsc // a fresh ESC restarts the lookahead window
            } else if byte == 0x5D { // ']' — OSC start (BEL- or ST-terminated)
                state = .controlStringSkipping(allowsBEL: true)
            } else if byte == 0x50 { // 'P' — DCS start (ST-terminated only)
                state = .controlStringSkipping(allowsBEL: false)
            } else if byte == 0x5E { // '^' — PM start (ST-terminated only)
                state = .controlStringSkipping(allowsBEL: false)
            } else {
                state = .ground
            }
        case .apcAwaitingMarker:
            if byte == 0x47 { // 'G' — Kitty graphics APC
                state = .apcAccumulating
            } else if byte == 0x1B {
                abortAPC(reprocessing: byte)
            } else if byte == 0x9C || byte == 0x07 {
                // C1 ST or BEL arriving before the command marker: no command
                // byte was ever accumulated, so — mirroring SwiftTerm, whose
                // shared apc/oscEnd action never dispatches an empty payload
                // — there's nothing to complete, only to abandon.
                clearRawFrame()
                state = .ground
            } else {
                state = .apcSkipping // some other APC payload; not our subset
            }
        case .apcAccumulating:
            if byte == 0x1B {
                state = .apcAccumulatingEsc
            } else if byte == 0x9C || byte == 0x07 {
                // C1 ST (0x9C) or BEL (0x07): SwiftTerm's own table treats
                // both, alongside the 7-bit `ESC \` handled below, as valid
                // terminators for an APC string, so a frame ending on either
                // completes successfully exactly like a full ST would.
                completeFrame()
                state = .ground
            } else if rawFrame.count >= remoteKittyMaxRawFrameBytes {
                // Overflow: drop the frame and resynchronize on the next
                // terminator so a later valid frame still parses.
                clearRawFrame()
                state = .apcSkipping
            } else {
                rawFrame.append(byte)
            }
        case .apcAccumulatingEsc:
            if byte == 0x5C { // '\' — ST, frame complete
                completeFrame()
                state = .ground
            } else {
                abortAPC(reprocessing: byte)
            }
        case .apcSkipping:
            if byte == 0x1B {
                state = .apcSkippingEsc
            } else if byte == 0x9C || byte == 0x07 {
                // Terminates the abandoned (unsupported-subset) frame, same
                // as `ESC \` would via `.apcSkippingEsc` below — discarded,
                // never completed, since it was never our own Kitty subset.
                clearRawFrame()
                state = .ground
            }
        case .apcSkippingEsc:
            if byte == 0x5C {
                state = .ground
            } else if byte == 0x5F {
                // '_' immediately after the ESC we were watching as a possible
                // ST: this is the universal APC-start marker, so a fresh frame
                // begins right here rather than being swallowed back into skip
                // mode (which would otherwise let this frame's own terminator
                // masquerade as the end of the abandoned one).
                clearRawFrame()
                state = .apcAwaitingMarker
            } else if byte != 0x1B {
                state = .apcSkipping
            }
        case .controlStringSkipping(let allowsBEL):
            if allowsBEL && byte == 0x07 { // BEL — OSC's alternate terminator
                state = .ground
            } else if byte == 0x9C { // C1 ST — terminates OSC/DCS/PM alike
                state = .ground
            } else if byte == 0x1B {
                state = .controlStringSkippingEsc(allowsBEL: allowsBEL)
            }
            // Any other byte — including one that would otherwise look like
            // our own APC start (`_`) or its marker (`G`) — is just more of
            // this string's payload: a string sequence never nests, so only
            // its own terminator (checked above/below) can ever end it.
        case .controlStringSkippingEsc(let allowsBEL):
            if byte == 0x5C { // '\' — ST, string complete
                state = .ground
            } else if byte != 0x1B {
                // Not a real ST after all: back into the string body, and
                // this byte (which could itself be `_`) is simply more
                // payload, never a fresh APC/OSC/DCS/PM marker.
                state = .controlStringSkipping(allowsBEL: allowsBEL)
            }
            // else: a fresh ESC keeps this lookahead window open, mirroring
            // `.sawEsc`'s own handling of consecutive ESCs.
        }
    }

    /// Discards any partially buffered frame and resynchronizes, then
    /// reprocesses `byte` — so a byte that turned out not to be a valid ST is
    /// never silently swallowed. Special-cased for `byte == '_'`: since the
    /// ESC that led here was already consumed, falling through to `.ground`
    /// and reprocessing `_` there would lose the "ESC _" prefix entirely
    /// (`.ground` only reacts to a *subsequent* ESC) — so a fresh APC starts
    /// directly instead, exactly as `.apcSkippingEsc` does for the same byte.
    private func abortAPC(reprocessing byte: UInt8) {
        clearRawFrame()
        if byte == 0x5F {
            state = .apcAwaitingMarker
            return
        }
        state = .ground
        process(byte)
    }

    /// CAN/SUB "anywhere" cancellation (see `process(_:)`): unconditionally
    /// discards any partially buffered frame and resets to `.ground`, never
    /// completing or reprocessing the cancelling byte itself.
    private func cancelSequence() {
        clearRawFrame()
        state = .ground
    }

    /// Empties `rawFrame`, releasing its underlying storage
    /// (`keepingCapacity: false`) if it had grown past
    /// `remoteKittyLargeBufferReleaseThreshold` before being discarded — so a
    /// frame that grew large (e.g. right up to `remoteKittyMaxRawFrameBytes`)
    /// doesn't leave that much capacity pinned per terminal indefinitely.
    private func clearRawFrame() {
        if rawFrame.count > remoteKittyLargeBufferReleaseThreshold {
            rawFrame.removeAll(keepingCapacity: false)
        } else {
            rawFrame.removeAll(keepingCapacity: true)
        }
    }

    private func completeFrame() {
        let frame = rawFrame
        clearRawFrame()
        let controlBytes: ArraySlice<UInt8>
        let payloadBytes: ArraySlice<UInt8>
        if let semicolon = frame.firstIndex(of: 0x3B) {
            controlBytes = frame[frame.startIndex ..< semicolon]
            payloadBytes = frame[(semicolon + 1)...]
        } else {
            controlBytes = frame[...]
            payloadBytes = frame[frame.endIndex...]
        }
        guard let control = String(bytes: controlBytes, encoding: .ascii) else { return }
        handleControlData(Self.parseControlData(control), payload: payloadBytes)
    }

    private static func parseControlData(_ control: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in control.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    // MARK: Command handling

    private func handleControlData(_ keys: [String: String], payload: ArraySlice<UInt8>) {
        if let action = keys["a"] {
            switch action {
            case "T", "t":
                beginTransmission(keys: keys, payload: payload)
            case "d":
                handleDelete(keys: keys)
            default:
                break // unsupported action (placement/query/animation/...): ignore
            }
            return
        }
        // No action key at all: only meaningful as an `m=1`/`m=0` continuation
        // chunk of an already-started transmission.
        appendContinuation(payload: payload, more: keys["m"] == "1")
    }

    private func beginTransmission(keys: [String: String], payload: ArraySlice<UInt8>) {
        // The protocol requires a client to finish all chunks of a transmission
        // before sending another graphics command, so a fresh start always means
        // any previous in-flight transmission is incomplete — abandon it.
        resetPendingTransmission()

        let transmissionMedium = keys["t"] ?? "d"
        guard transmissionMedium == "d",
              keys["f"] == "100",
              keys["U"] == "1",
              let idString = keys["i"],
              let imageId = UInt32(idString),
              imageId >= 1, imageId <= 0xFFFFFF
        else {
            return // outside our supported subset: fail closed, ignore entirely
        }

        pendingImageId = imageId
        appendPayload(payload)
        if keys["m"] != "1" { finalizePending() }
    }

    private func appendContinuation(payload: ArraySlice<UInt8>, more: Bool) {
        guard pendingImageId != nil else { return }
        appendPayload(payload)
        if !more { finalizePending() }
    }

    private func appendPayload(_ payload: ArraySlice<UInt8>) {
        guard pendingImageId != nil else { return }
        // Reserved against the process-wide pending budget *before* actually
        // appending, so a chunk that would push either this instance's own
        // local cap or the shared cross-terminal cap over its bound is never
        // partially retained — the whole in-flight transmission is discarded
        // instead, exactly like any other overflow.
        guard pendingBase64.count + payload.count <= maxAccumulatedBase64Bytes,
              budget.reservePending(owner: self, additionalBytes: payload.count)
        else {
            resetPendingTransmission()
            return
        }
        pendingBase64.append(contentsOf: payload)
    }

    private func finalizePending() {
        defer { resetPendingTransmission() }
        guard let imageId = pendingImageId,
              let decoded = Data(base64Encoded: Data(pendingBase64)),
              decoded.count <= remoteKittyMaxDecodedImageBytes,
              Self.validatePNG(decoded)
        else { return }
        retain(imageId: imageId, data: decoded)
    }

    /// Ends whatever in-flight transmission is currently buffered — on
    /// success, failure, overflow, a fresh `beginTransmission` abandoning the
    /// previous one, or an explicit delete/clear — releasing this exact
    /// buffer's process-wide pending-byte reservation (never partially: the
    /// whole in-flight transmission is one all-or-nothing unit) and its local
    /// storage, dropping capacity if it had grown large.
    private func resetPendingTransmission() {
        pendingImageId = nil
        clearPendingBase64()
        budget.releasePending(owner: self)
    }

    /// Called by `RemoteKittyImageCaptureBudget` when it needs to abort this
    /// exact owner's in-flight transmission to make room for a different
    /// owner's pending reservation (see `RemoteKittyImageCaptureBudget
    /// .reservePending`) — the pending-bytes counterpart to `evictForBudget`
    /// for retained entries. Safe unconditionally: unvalidated pending bytes
    /// aren't real data any other owner could be relying on yet. Never
    /// re-notifies the budget (it already removed this owner's reservation
    /// on its side, which is what triggered this call in the first place) —
    /// calling `resetPendingTransmission` here instead would double-release.
    func abortPendingForBudget() {
        pendingImageId = nil
        clearPendingBase64()
    }

    /// Empties `pendingBase64`, releasing its underlying storage
    /// (`keepingCapacity: false`) if it had grown past
    /// `remoteKittyLargeBufferReleaseThreshold` before being discarded — so a
    /// large in-flight buffer doesn't leave that much capacity pinned per
    /// terminal indefinitely once its transmission ends.
    private func clearPendingBase64() {
        if pendingBase64.count > remoteKittyLargeBufferReleaseThreshold {
            pendingBase64.removeAll(keepingCapacity: false)
        } else {
            pendingBase64.removeAll(keepingCapacity: true)
        }
    }

    /// Requires a structurally *complete* PNG of PNG type — ImageIO only
    /// parses the container's chunks/metadata here (`CGImageSourceGetStatusAtIndex`),
    /// it never decodes/allocates the full pixel bitmap, so this stays cheap
    /// even for large images while still rejecting truncated/malformed data
    /// that a signature+IHDR-only check would have accepted.
    private static func validatePNG(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), type as String == UTType.png.identifier,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        guard width > 0, height > 0,
              width <= remoteKittyMaxImageDimension,
              height <= remoteKittyMaxImageDimension
        else { return false }
        guard width * height <= remoteKittyMaxImagePixels else { return false }
        return true
    }

    /// Allocates this instance's next version: monotonic `counter` in the low
    /// 32 bits, this instance's fixed `epoch` in the high 32 bits.
    private func nextVersion() -> UInt64 {
        let version = (UInt64(epoch) << 32) | nextCounter
        nextCounter += 1
        return version
    }

    private func retain(imageId: UInt32, data: Data) {
        let version = nextVersion()
        let key = StoredKey(imageId: imageId, version: version)
        order.append(key)
        dataByKey[key] = data
        totalBytes += data.count
        latestVersion[imageId] = version
        // A finalized, validly-transmitted image always (re)activates its
        // placement — whether `imageId` was previously active, had its
        // placement deleted but was still retained, or is being seen for the
        // first time entirely.
        activeImageIds.insert(imageId)
        // A fresh retain always installs a new *current* version for
        // `imageId` and (re)activates it, so this always changes what a scan
        // would currently discover for it.
        imageAvailabilityGeneration &+= 1
        budget.register(owner: self, imageId: imageId, version: version, bytes: data.count)
        enforceLocalBounds()
    }

    /// Removes a single retained entry, keeping `order`/`dataByKey`/`totalBytes`/
    /// `latestVersion` in lockstep. `notifyBudget` is false only when this is
    /// itself being called *from* the budget manager's own eviction (avoiding a
    /// pointless unregister-of-something-it-just-removed callback).
    private func removeStoredKey(_ key: StoredKey, notifyBudget: Bool) {
        guard let data = dataByKey.removeValue(forKey: key) else { return }
        totalBytes -= data.count
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        if latestVersion[key.imageId] == key.version {
            latestVersion.removeValue(forKey: key.imageId)
            // The entry just reclaimed was `imageId`'s *current* version. A
            // scan would no longer find it *only if* the id was still active
            // (an already-inactive id was never advertised in the first
            // place, so its data quietly aging out here doesn't change what
            // a scan would currently discover — bumping would be a pointless
            // extra generation bump). The active set itself is untouched:
            // per the spec, retained-data eviction never implies a placement
            // was deleted, only that it can no longer be served.
            if activeImageIds.contains(key.imageId) {
                imageAvailabilityGeneration &+= 1
            }
        }
        if notifyBudget {
            budget.unregister(owner: self, imageId: key.imageId, version: key.version)
        }
    }

    /// Called by `RemoteKittyImageCaptureBudget` when it needs to reclaim this
    /// exact entry to enforce the process-wide bound. Never re-notifies the
    /// budget (it's already accounted for the removal on its side).
    func evictForBudget(imageId: UInt32, version: UInt64) {
        removeStoredKey(StoredKey(imageId: imageId, version: version), notifyBudget: false)
    }

    private func enforceLocalBounds() {
        while order.count > remoteKittyMaxRetainedEntries || totalBytes > remoteKittyMaxTotalRetainedBytes {
            guard let victim = pickEvictionVictim() else { break }
            removeStoredKey(victim, notifyBudget: true)
        }
    }

    /// Prefers evicting the oldest already-superseded version (an id's older,
    /// grace-retained entry) over any still-current one, so bumping into the
    /// bound never drops a version a client might currently be looking at as
    /// long as some obsolete version is available to sacrifice instead.
    private func pickEvictionVictim() -> StoredKey? {
        guard !order.isEmpty else { return nil }
        for key in order where latestVersion[key.imageId] != key.version {
            return key
        }
        return order.first
    }

    // MARK: Deletion

    private func handleDelete(keys: [String: String]) {
        let mode = keys["d"] ?? "a"
        switch mode {
        case "A":
            clearAll()
        case "I":
            guard let idString = keys["i"], let imageId = UInt32(idString) else { return }
            removeAllVersions(imageId: imageId)
        case "a":
            clearAllActivePlacements()
        case "i":
            guard let idString = keys["i"], let imageId = UInt32(idString) else { return }
            clearActivePlacement(imageId: imageId)
        default:
            // Every other delete mode this instance doesn't specifically
            // understand the scoping of (column/row/z-index/point/animation-
            // frame targeted deletes, upper- or lowercase) is handled fail
            // closed rather than silently ignored: an uppercase mode also
            // deletes underlying data per the Kitty spec, and since this
            // capture can't reason about exactly *which* placements/data such
            // a delete would target, it conservatively treats it the same as
            // the one fully-scoped delete it does understand at that same
            // tier (`A` for uppercase, `a` for lowercase) — clearing more
            // than a real terminal might have, but never leaving a ghost.
            if mode.first?.isUppercase == true {
                clearAll()
            } else {
                clearAllActivePlacements()
            }
        }
    }

    /// Removes only `imageId`'s active-placement flag — its retained PNG
    /// bytes (all still-grace-retained versions) are left untouched. Mirrors
    /// the Kitty spec's lowercase `d=i`: a placement delete, not a data
    /// delete. `currentVersion(for:)` returns `nil` for this id afterward
    /// (no more ghost) until a fresh transmission reactivates it.
    private func clearActivePlacement(imageId: UInt32) {
        guard activeImageIds.remove(imageId) != nil else { return }
        if latestVersion[imageId] != nil {
            // Was actually advertised (active *and* retained) before this
            // delete — now it isn't, so a scan's discoverable state changed.
            imageAvailabilityGeneration &+= 1
        }
    }

    /// Removes every id's active-placement flag — retained PNG bytes for
    /// every id are left untouched. Mirrors the Kitty spec's lowercase
    /// `d=a`, and is also the fail-closed fallback for any other lowercase
    /// delete mode this capture doesn't specifically scope.
    private func clearAllActivePlacements() {
        guard !activeImageIds.isEmpty else { return }
        // Only ids that were both active *and* still had retained data were
        // actually advertised before this clear — anything else clearing
        // here doesn't change what a scan would currently discover.
        let hadAnyAdvertised = activeImageIds.contains { latestVersion[$0] != nil }
        activeImageIds.removeAll()
        if hadAnyAdvertised { imageAvailabilityGeneration &+= 1 }
    }

    private func clearAll() {
        let hadAnyAdvertised = activeImageIds.contains { latestVersion[$0] != nil }
        for key in order {
            budget.unregister(owner: self, imageId: key.imageId, version: key.version)
        }
        order.removeAll()
        dataByKey.removeAll()
        latestVersion.removeAll()
        activeImageIds.removeAll()
        totalBytes = 0
        if hadAnyAdvertised { imageAvailabilityGeneration &+= 1 }
        resetPendingTransmission()
    }

    private func removeAllVersions(imageId: UInt32) {
        var kept: [StoredKey] = []
        kept.reserveCapacity(order.count)
        for key in order {
            if key.imageId == imageId {
                if let data = dataByKey.removeValue(forKey: key) { totalBytes -= data.count }
                budget.unregister(owner: self, imageId: key.imageId, version: key.version)
            } else {
                kept.append(key)
            }
        }
        order = kept
        let hadData = latestVersion.removeValue(forKey: imageId) != nil
        let wasActive = activeImageIds.remove(imageId) != nil
        // Advertised availability only changes if `imageId` was both active
        // and had retained data before this — either alone means it wasn't
        // currently discoverable by a scan, so removing the other half here
        // doesn't change anything a scan would see.
        if wasActive && hadData {
            imageAvailabilityGeneration &+= 1
        }
        if pendingImageId == imageId {
            resetPendingTransmission()
        }
    }
}
