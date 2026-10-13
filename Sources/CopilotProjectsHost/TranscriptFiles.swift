import Foundation
import CopilotProjectsProtocol

/// The tracker publishes a tab's transcript as two files. The sealed file
/// (`transcript.json`) holds the finished turns and is rewritten only when they
/// change; the live file (`transcript-live.json`) holds the turn in progress and
/// is rewritten as it streams. Readers see the two merged into a version 3
/// snapshot, the shape every consumer and remote client already knows.
///
/// A version 3 sealed file comes from a tracker that predates the split: it
/// carries its turn in progress inline, so a live file beside it is stale.
enum TranscriptFiles {
    static let mergedSchemaVersion = 3
    static let sealedSchemaVersion = 4
    static let liveSchemaVersion = 1

    private struct Sealed: Decodable {
        let schemaVersion: Int
        let updatedAt: Date
        let copilotSessionId: String
        let turns: [TranscriptTurn]
        let totalTurns: Int?
        let droppedTurns: [TranscriptTurn]?
        /// Identifies this write of the sealed file; a live file names the
        /// revision it extends.
        let revision: String?
        /// While the same turn is still in progress, the revision the live
        /// file on disk extended when this file was written, so that turn
        /// stays visible until its own rewrite lands.
        let previousRevision: String?

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, updatedAt, copilotSessionId, turns, totalTurns
            case droppedTurns, revision, previousRevision
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            copilotSessionId = try container.decode(String.self, forKey: .copilotSessionId)
            turns = try container.decode([TranscriptTurn].self, forKey: .turns)
            totalTurns = try container.decodeIfPresent(Int.self, forKey: .totalTurns)
            // A malformed recovery buffer must never cost the transcript itself.
            droppedTurns = try? container.decodeIfPresent([TranscriptTurn].self, forKey: .droppedTurns)
            revision = try container.decodeIfPresent(String.self, forKey: .revision)
            previousRevision = try container.decodeIfPresent(String.self, forKey: .previousRevision)
        }

        func accepts(_ live: Live) -> Bool {
            guard live.schemaVersion == TranscriptFiles.liveSchemaVersion,
                  live.copilotSessionId == copilotSessionId,
                  let revision,
                  live.baseRevision == revision || live.baseRevision == previousRevision
            else {
                return false
            }
            return !turns.contains { $0.id == live.turn.id }
        }
    }

    private struct Live: Decodable {
        let schemaVersion: Int
        let copilotSessionId: String
        let baseRevision: String
        let updatedAt: Date
        let turn: TranscriptTurn
    }

    /// Merges the sealed file's bytes with the live file's. Read the live file
    /// first: the tracker replaces the sealed file before the live one, so a
    /// live file read first is never ahead of the sealed file read after it.
    /// `nil` when the sealed file is not a transcript this host understands.
    static func snapshot(
        sealed sealedData: Data,
        live liveData: Data?,
        decoder: JSONDecoder
    ) -> TranscriptSnapshot? {
        guard let sealed = try? decoder.decode(Sealed.self, from: sealedData) else {
            return nil
        }
        let live: Live?
        switch sealed.schemaVersion {
        case mergedSchemaVersion:
            live = nil
        case sealedSchemaVersion:
            live = liveData
                .flatMap { try? decoder.decode(Live.self, from: $0) }
                .flatMap { sealed.accepts($0) ? $0 : nil }
        default:
            return nil
        }
        return TranscriptSnapshot(
            schemaVersion: mergedSchemaVersion,
            updatedAt: live.map { max(sealed.updatedAt, $0.updatedAt) } ?? sealed.updatedAt,
            copilotSessionId: sealed.copilotSessionId,
            turns: live.map { sealed.turns + [$0.turn] } ?? sealed.turns,
            totalTurns: sealed.totalTurns,
            droppedTurns: sealed.droppedTurns
        )
    }
}
