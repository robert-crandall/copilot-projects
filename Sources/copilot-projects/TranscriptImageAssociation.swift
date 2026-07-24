import Foundation
import CopilotProjectsProtocol

/// Pure association of currently-retained inline images to transcript turns.
///
/// An image is attached to the turn that was *active* when it was displayed —
/// the turn with the greatest `startedAt` that is still `<= displayedAt`.
/// This deliberately uses only `startedAt` (never `endedAt`), so the still-open
/// streaming turn's ever-growing `[startedAt, now]` window can't reshuffle
/// associations between requests: once a turn exists with a `startedAt` at or
/// before an image's display time, that image's turn assignment is stable.
///
/// Images displayed before the first turn began are dropped (nothing to attach
/// them to). Only currently-retained images are ever passed in, so an attached
/// ref's exact `(imageId, version)` is always fetchable — no 404 tombstones.
enum TranscriptImageAssociation {
    static func attach(
        images: [RemoteKittyImageCapture.RetainedImageInfo],
        to snapshot: TranscriptSnapshot
    ) -> TranscriptSnapshot {
        guard !images.isEmpty, !snapshot.turns.isEmpty else { return snapshot }
        let turns = snapshot.turns

        // turnIndex -> imageId -> chosen (newest) info for that turn.
        var byTurn: [Int: [UInt32: RemoteKittyImageCapture.RetainedImageInfo]] = [:]
        for image in images {
            guard let turnIndex = Self.activeTurnIndex(turns, at: image.displayedAt) else {
                continue
            }
            var perImage = byTurn[turnIndex] ?? [:]
            if let existing = perImage[image.imageId] {
                if image.version > existing.version { perImage[image.imageId] = image }
            } else {
                perImage[image.imageId] = image
            }
            byTurn[turnIndex] = perImage
        }
        guard !byTurn.isEmpty else { return snapshot }

        var newTurns = turns
        for (turnIndex, perImage) in byTurn {
            let refs = perImage.values
                .sorted {
                    if $0.displayedAt != $1.displayedAt { return $0.displayedAt < $1.displayedAt }
                    return $0.imageId < $1.imageId
                }
                .map { TranscriptImageRef(imageId: $0.imageId, contentVersion: $0.version) }
            let turn = turns[turnIndex]
            newTurns[turnIndex] = TranscriptTurn(
                id: turn.id,
                startedAt: turn.startedAt,
                endedAt: turn.endedAt,
                kind: turn.kind,
                userContent: turn.userContent,
                assistantMessages: turn.assistantMessages,
                tools: turn.tools,
                isAborted: turn.isAborted,
                images: refs
            )
        }
        return TranscriptSnapshot(
            schemaVersion: snapshot.schemaVersion,
            updatedAt: snapshot.updatedAt,
            copilotSessionId: snapshot.copilotSessionId,
            turns: newTurns
        )
    }

    /// Index of the turn with the greatest `startedAt <= time`, or `nil` if no
    /// turn had started by `time`. Linear scan; both inputs are bounded small
    /// (turns <= ~200, images <= per-session retention cap).
    static func activeTurnIndex(_ turns: [TranscriptTurn], at time: Date) -> Int? {
        var best: Int?
        for (index, turn) in turns.enumerated() where turn.startedAt <= time {
            if let current = best {
                if turn.startedAt > turns[current].startedAt { best = index }
            } else {
                best = index
            }
        }
        return best
    }
}
