import Foundation

/// One session's agent-activity snapshot as a scan found it on disk.
struct AgentActivityRead {
    enum Outcome {
        /// There's no snapshot file.
        case missing
        /// The file matches the cached signature, so the cached snapshot stands.
        case unchanged
        /// The file exists but couldn't be read (a transient `open()` denial or a
        /// racing writer); the cache is left alone so the next scan retries.
        case unreadable
        /// Read and decoded; a malformed file decodes to nil and is cached as such.
        case read(FileSignature, AgentActivitySnapshot?)
    }

    let outcome: Outcome
    /// Taken after the read, so a snapshot is never judged before it was read.
    let readAt: Date
}

/// Reads sessions' `<id>.agent-activity.json` files. It touches no app state, so
/// scans can run it off the main actor: an endpoint-security agent can hold each
/// `open()` of a freshly rewritten heartbeat for tens of milliseconds.
enum AgentActivityReader {
    typealias Read = @Sendable (
        _ sessionIds: [String],
        _ directory: URL,
        _ cached: [String: FileSignature],
        _ clock: () -> Date
    ) -> [String: AgentActivityRead]

    static let read: Read = { sessionIds, directory, cached, clock in
        let fm = FileManager.default
        let decoder = JSONDecoder()
        var reads: [String: AgentActivityRead] = [:]
        for sessionId in sessionIds {
            let path = directory
                .appendingPathComponent("\(sessionId).agent-activity.json", isDirectory: false).path
            let outcome: AgentActivityRead.Outcome
            if let attributes = try? fm.attributesOfItem(atPath: path) {
                let signature = FileSignature(attributes: attributes)
                if cached[sessionId] == signature {
                    outcome = .unchanged
                } else if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    outcome = .read(signature, try? decoder.decode(AgentActivitySnapshot.self, from: data))
                } else {
                    outcome = .unreadable
                }
            } else {
                outcome = .missing
            }
            reads[sessionId] = AgentActivityRead(outcome: outcome, readAt: clock())
        }
        return reads
    }
}
