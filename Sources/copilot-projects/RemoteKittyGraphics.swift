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

    /// Groups `cells` by image id, splits each id's cells into 4-neighbor
    /// connected components (so two disjoint placements sharing an id never
    /// merge into one bounding box), and emits one placement per component —
    /// only for ids with a `currentVersion`, i.e. a still-retained capture.
    /// `firstLine` converts the caller's absolute/viewport line ids into rows
    /// relative to the emitted screen. Sorted deterministically by
    /// (line, column, imageId) so repeated scans of the same grid are stable.
    ///
    /// Emits at most `remoteKittyMaxEmittedPlacements` placements: image ids
    /// are visited in ascending order and, within an id, components are
    /// seeded deterministically (smallest `(lineId, col)` first) rather than
    /// via `Set`'s unordered iteration, so which components are discovered
    /// before the cap is hit — and therefore which ones are emitted — never
    /// depends on hashing/iteration order. Component discovery itself stops
    /// the instant the cap is reached, so a pathological grid never pays for
    /// flood-filling components that would just be discarded.
    static func scan(
        cells: [RemoteKittyGridCell],
        firstLine: Int,
        currentVersion: (UInt32) -> UInt64?
    ) -> [RemoteTerminalImagePlacement] {
        guard !cells.isEmpty else { return [] }

        var byImage: [UInt32: Set<Coordinate>] = [:]
        for cell in cells {
            byImage[cell.imageId, default: []].insert(Coordinate(lineId: cell.lineId, col: cell.col))
        }

        var placements: [RemoteTerminalImagePlacement] = []
        imageLoop: for imageId in byImage.keys.sorted() {
            guard let version = currentVersion(imageId), var remaining = byImage[imageId] else { continue }
            while !remaining.isEmpty {
                if placements.count >= remoteKittyMaxEmittedPlacements { break imageLoop }
                let start = remaining.min { ($0.lineId, $0.col) < ($1.lineId, $1.col) }!
                remaining.remove(start)
                var component: [Coordinate] = [start]
                var frontier = [start]
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
                    }
                }
                let lineIds = component.map(\.lineId)
                let cols = component.map(\.col)
                guard let minLine = lineIds.min(), let maxLine = lineIds.max(),
                      let minCol = cols.min(), let maxCol = cols.max() else { continue }
                placements.append(RemoteTerminalImagePlacement(
                    imageId: imageId,
                    contentVersion: version,
                    line: minLine - firstLine,
                    column: minCol,
                    rows: maxLine - minLine + 1,
                    columns: maxCol - minCol + 1
                ))
            }
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

    // Content versions are `(epoch << 32) | counter`: `epoch` is fixed for this
    // instance's whole lifetime and `counter` is monotonic within it, so two
    // `RemoteKittyImageCapture` instances for the same session (e.g. the first
    // recreated after a relaunch) never hand out the same version number for
    // the same image id — a client can't have a stale cached fetch URL from
    // the old instance accidentally resolve against the new one's data.
    private let epoch: UInt32
    private var nextCounter: UInt64 = 1
    private let budget: RemoteKittyImageCaptureBudget

    /// - Parameters:
    ///   - epoch: The high 32 bits every version handed out by this instance
    ///     carries. Defaults to a fresh random value per instance (production
    ///     behavior); tests inject a fixed value for deterministic version
    ///     assertions and to prove distinct epochs never collide.
    ///   - budget: The process-wide budget this instance's retained bytes are
    ///     accounted against. Defaults to the real shared singleton; tests
    ///     inject an isolated instance so cross-test process state can never
    ///     leak into an assertion about global bounds.
    init(
        epoch: UInt32 = UInt32.random(in: UInt32.min ... UInt32.max),
        budget: RemoteKittyImageCaptureBudget? = nil
    ) {
        self.epoch = epoch
        // `budget`'s default can't be spelled as `= .shared` in the parameter
        // list itself: default-argument expressions aren't evaluated in the
        // enclosing (main-actor) isolation context, so referencing a
        // main-actor-isolated static there is a Swift 6 isolation error.
        // Resolving it here, inside the (main-actor-isolated) initializer
        // body, is equivalent for every real caller.
        self.budget = budget ?? .shared
    }

    /// Feeds raw terminal output bytes. Safe to call with any chunking of the
    /// underlying byte stream — the scanner carries state across calls, so a
    /// frame split across arbitrary `ingest` boundaries still parses.
    func ingest(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            process(byte)
        }
    }

    /// The newest version currently retained for `imageId`, or `nil` if nothing
    /// (or nothing still-retained) has been captured for it.
    func currentVersion(for imageId: UInt32) -> UInt64? {
        latestVersion[imageId]
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
        switch state {
        case .ground:
            if byte == 0x1B { state = .sawEsc }
        case .sawEsc:
            if byte == 0x5F { // '_' — APC start
                rawFrame.removeAll(keepingCapacity: true)
                state = .apcAwaitingMarker
            } else if byte == 0x1B {
                state = .sawEsc // a fresh ESC restarts the lookahead window
            } else {
                state = .ground
            }
        case .apcAwaitingMarker:
            if byte == 0x47 { // 'G' — Kitty graphics APC
                state = .apcAccumulating
            } else if byte == 0x1B {
                abortAPC(reprocessing: byte)
            } else {
                state = .apcSkipping // some other APC payload; not our subset
            }
        case .apcAccumulating:
            if byte == 0x1B {
                state = .apcAccumulatingEsc
            } else if rawFrame.count >= remoteKittyMaxRawFrameBytes {
                // Overflow: drop the frame and resynchronize on the next
                // terminator so a later valid frame still parses.
                rawFrame.removeAll(keepingCapacity: true)
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
            if byte == 0x1B { state = .apcSkippingEsc }
        case .apcSkippingEsc:
            if byte == 0x5C {
                state = .ground
            } else if byte == 0x5F {
                // '_' immediately after the ESC we were watching as a possible
                // ST: this is the universal APC-start marker, so a fresh frame
                // begins right here rather than being swallowed back into skip
                // mode (which would otherwise let this frame's own terminator
                // masquerade as the end of the abandoned one).
                rawFrame.removeAll(keepingCapacity: true)
                state = .apcAwaitingMarker
            } else if byte != 0x1B {
                state = .apcSkipping
            }
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
        rawFrame.removeAll(keepingCapacity: true)
        if byte == 0x5F {
            state = .apcAwaitingMarker
            return
        }
        state = .ground
        process(byte)
    }

    private func completeFrame() {
        let frame = rawFrame
        rawFrame.removeAll(keepingCapacity: true)
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
        pendingImageId = nil
        pendingBase64.removeAll(keepingCapacity: true)

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
        guard pendingBase64.count + payload.count <= remoteKittyMaxAccumulatedBase64Bytes else {
            // Overflow: discard the whole in-flight transmission rather than
            // retain a truncated/mismatched image.
            pendingImageId = nil
            pendingBase64.removeAll(keepingCapacity: true)
            return
        }
        pendingBase64.append(contentsOf: payload)
    }

    private func finalizePending() {
        defer {
            pendingImageId = nil
            pendingBase64.removeAll(keepingCapacity: true)
        }
        guard let imageId = pendingImageId,
              let decoded = Data(base64Encoded: Data(pendingBase64)),
              decoded.count <= remoteKittyMaxDecodedImageBytes,
              Self.validatePNG(decoded)
        else { return }
        retain(imageId: imageId, data: decoded)
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
        switch keys["d"] ?? "a" {
        case "A":
            clearAll()
        case "I":
            guard let idString = keys["i"], let imageId = UInt32(idString) else { return }
            removeAllVersions(imageId: imageId)
        default:
            break // lowercase targets only delete placements, not retained data
        }
    }

    private func clearAll() {
        for key in order {
            budget.unregister(owner: self, imageId: key.imageId, version: key.version)
        }
        order.removeAll()
        dataByKey.removeAll()
        latestVersion.removeAll()
        totalBytes = 0
        pendingImageId = nil
        pendingBase64.removeAll(keepingCapacity: true)
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
        latestVersion.removeValue(forKey: imageId)
        if pendingImageId == imageId {
            pendingImageId = nil
            pendingBase64.removeAll(keepingCapacity: true)
        }
    }
}
