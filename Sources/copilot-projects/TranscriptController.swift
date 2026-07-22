import Foundation
import Combine
import Darwin
import CopilotProjectsCore
import CopilotProjectsProtocol

@MainActor
final class TranscriptController: ObservableObject {
    nonisolated private static let quarantineLock = NSLock()

    private struct TranscriptOwner: Decodable {
        let appSessionId: String?
        let copilotSessionId: String?
        let pid: pid_t
    }

    private struct TranscriptQuarantine: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let foreignCopilotSessionIds: Set<String>
    }

    private struct LoadSignature: Equatable, Sendable {
        let transcript: FileSignature
        let owner: FileSignature?
        let quarantine: FileSignature?
    }

    private struct LoadResult: Sendable {
        let signature: LoadSignature?
        let snapshot: TranscriptSnapshot?
    }

    @Published private(set) var snapshot: TranscriptSnapshot?

    let sessionId: String

    private var directorySource: DispatchSourceFileSystemObject?
    private var fallbackTimer: Timer?
    private var signature: LoadSignature?
    private var reloadGeneration = 0
    private var started = false

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    deinit {
        directorySource?.cancel()
        fallbackTimer?.invalidate()
    }

    func start() {
        guard !started else { return }
        started = true
        watchSessionsDirectory()
        reload()
    }

    private func watchSessionsDirectory() {
        Paths.ensureStateDir()
        let descriptor = open(Paths.sessionsDir.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.reload(after: 0.03) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            directorySource = source
        }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func reload(after delay: TimeInterval = 0) {
        reloadGeneration += 1
        let generation = reloadGeneration
        let previousSignature = signature
        let currentSessionId = sessionId
        let path = Paths.transcriptSnapshotPath(sessionId: currentSessionId)
        Task.detached {
            if delay > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
            guard let result = Self.load(
                sessionId: currentSessionId,
                path: path,
                previousSignature: previousSignature
            ) else { return }
            await MainActor.run { [weak self] in
                guard let self, generation == reloadGeneration else { return }
                signature = result.signature
                snapshot = result.snapshot
            }
        }
    }

    nonisolated private static func load(
        sessionId: String,
        path: String,
        previousSignature: LoadSignature?
    ) -> LoadResult? {
        guard let signature = loadSignature(
            sessionId: sessionId,
            transcriptPath: path
        ) else {
            guard previousSignature != nil else { return nil }
            return LoadResult(signature: nil, snapshot: nil)
        }
        guard signature != previousSignature else { return nil }
        guard transcriptOwnerAllowsRead(sessionId: sessionId) else {
            return LoadResult(signature: signature, snapshot: nil)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        let decoder = transcriptDecoder()
        guard let snapshot = try? decoder.decode(TranscriptSnapshot.self, from: data),
              snapshot.schemaVersion == 3 else {
            return LoadResult(signature: signature, snapshot: nil)
        }
        guard transcriptQuarantineAllowsRead(
            sessionId: sessionId,
            snapshot: snapshot,
            expectedSignature: signature
        ) else {
            let current = loadSignature(sessionId: sessionId, transcriptPath: path)
            return LoadResult(
                signature: current == signature ? signature : nil,
                snapshot: nil
            )
        }
        return LoadResult(signature: signature, snapshot: snapshot)
    }

    nonisolated static func remoteRevision(sessionId: String) -> RemoteTranscriptRevision {
        return RemoteTranscriptRevision(
            sessionId: sessionId,
            generation: [
                fileGeneration(Paths.transcriptSnapshotPath(sessionId: sessionId)),
                fileGeneration(Paths.transcriptOwnerPath(sessionId: sessionId)),
                fileGeneration(Paths.transcriptQuarantinePath(sessionId: sessionId)),
            ].joined(separator: "|")
        )
    }

    nonisolated static func loadRemoteSnapshot(sessionId: String) -> TranscriptSnapshot {
        let path = Paths.transcriptSnapshotPath(sessionId: sessionId)
        guard let signature = loadSignature(
            sessionId: sessionId,
            transcriptPath: path
        ) else {
            return emptyRemoteSnapshot()
        }
        guard transcriptOwnerAllowsRead(sessionId: sessionId) else {
            return emptyRemoteSnapshot()
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count <= 6 * 1_024 * 1_024 else {
            return emptyRemoteSnapshot()
        }
        let decoder = transcriptDecoder()
        guard let snapshot = try? decoder.decode(TranscriptSnapshot.self, from: data),
              snapshot.schemaVersion == 3 else {
            return emptyRemoteSnapshot()
        }
        guard transcriptQuarantineAllowsRead(
            sessionId: sessionId,
            snapshot: snapshot,
            expectedSignature: signature
        ) else {
            return emptyRemoteSnapshot()
        }
        return snapshot
    }

    nonisolated private static func transcriptOwnerAllowsRead(
        sessionId: String
    ) -> Bool {
        let path = Paths.transcriptOwnerPath(sessionId: sessionId)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let owner = try? JSONDecoder().decode(TranscriptOwner.self, from: data),
              owner.pid > 0 else {
            return true
        }
        if let ownerSessionId = owner.appSessionId {
            let allows = ownerSessionId.caseInsensitiveCompare(sessionId) == .orderedSame
            if !allows {
                recordForeignTranscriptQuarantine(
                    sessionId: sessionId,
                    copilotSessionId: owner.copilotSessionId
                )
            }
            return allows
        }
        let snapshot = ProcessTree.snapshot()
        guard snapshot.nameOf[owner.pid] != nil else { return true }
        let environment = ProcessTree.inspect(owner.pid).env
        let allows = transcriptOwnerMatchesSession(
            sessionId: sessionId,
            ownerPID: owner.pid,
            snapshot: snapshot,
            environment: environment,
            dtachProcesses: ProcessTree.dtachProcesses(in: snapshot),
            sessionsDirectory: Paths.sessionsDir
        ) ?? true
        if !allows {
            recordForeignTranscriptQuarantine(
                sessionId: sessionId,
                copilotSessionId: owner.copilotSessionId
            )
        }
        return allows
    }

    nonisolated static func transcriptOwnerMatchesSession(
        sessionId: String,
        ownerPID: pid_t,
        snapshot: ProcessTree.Snapshot,
        environment: [String: String],
        dtachProcesses: [ProcessTree.DtachProcess],
        sessionsDirectory: URL
    ) -> Bool? {
        guard let resolved = ProcessTree.managedSessionId(
            for: ownerPID,
            fallbackSessionId: Env.sessionId(environment),
            sessionsDirectory: sessionsDirectory,
            in: snapshot,
            dtachProcesses: dtachProcesses
        ) else {
            return nil
        }
        return resolved.caseInsensitiveCompare(sessionId) == .orderedSame
    }

    nonisolated static func isCopilotSessionQuarantined(
        sessionId: String,
        copilotSessionId: String,
        directory: URL = Paths.sessionsDir
    ) -> Bool {
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        guard let quarantine = loadQuarantine(
            sessionId: sessionId,
            directory: directory
        ) else {
            return false
        }
        return quarantine.foreignCopilotSessionIds.contains(copilotSessionId)
    }

    nonisolated private static func recordForeignTranscriptQuarantine(
        sessionId: String,
        copilotSessionId: String?
    ) {
        if let copilotSessionId, UUID(uuidString: copilotSessionId) != nil {
            quarantineLock.lock()
            defer { quarantineLock.unlock() }
            let path = Paths.transcriptQuarantinePath(sessionId: sessionId)
            let existing = loadQuarantine(sessionId: sessionId)?
                .foreignCopilotSessionIds ?? []
            guard !existing.contains(copilotSessionId) else { return }
            let quarantine = TranscriptQuarantine(
                schemaVersion: TranscriptQuarantine.currentSchemaVersion,
                foreignCopilotSessionIds: existing.union([copilotSessionId])
            )
            if let data = try? JSONEncoder().encode(quarantine) {
                try? data.write(
                    to: URL(fileURLWithPath: path),
                    options: .atomic
                )
            }
        }
    }

    nonisolated private static func transcriptQuarantineAllowsRead(
        sessionId: String,
        snapshot: TranscriptSnapshot,
        expectedSignature: LoadSignature
    ) -> Bool {
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        guard loadSignature(
            sessionId: sessionId,
            transcriptPath: Paths.transcriptSnapshotPath(sessionId: sessionId)
        ) == expectedSignature else {
            return false
        }
        let path = Paths.transcriptQuarantinePath(sessionId: sessionId)
        guard let quarantine = loadQuarantine(sessionId: sessionId) else {
            return true
        }
        guard quarantine.foreignCopilotSessionIds.contains(
            snapshot.copilotSessionId
        ) else {
            try? FileManager.default.removeItem(atPath: path)
            return true
        }
        return false
    }

    nonisolated private static func fileGeneration(_ path: String) -> String {
        guard let signature = fileSignature(path) else { return "missing" }
        return "\(signature.fileNumber):\(signature.size):\(signature.modifiedAt)"
    }

    nonisolated private static func loadSignature(
        sessionId: String,
        transcriptPath: String
    ) -> LoadSignature? {
        guard let transcript = fileSignature(transcriptPath) else { return nil }
        return LoadSignature(
            transcript: transcript,
            owner: fileSignature(Paths.transcriptOwnerPath(sessionId: sessionId)),
            quarantine: fileSignature(Paths.transcriptQuarantinePath(sessionId: sessionId))
        )
    }

    nonisolated private static func fileSignature(_ path: String) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        else {
            return nil
        }
        return FileSignature(attributes: attributes)
    }

    nonisolated private static func loadQuarantine(
        sessionId: String,
        directory: URL = Paths.sessionsDir
    ) -> TranscriptQuarantine? {
        let path = directory
            .appendingPathComponent("\(sessionId).transcript-quarantine.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let quarantine = try? JSONDecoder().decode(
                  TranscriptQuarantine.self,
                  from: data
              ),
              quarantine.schemaVersion == TranscriptQuarantine.currentSchemaVersion else {
            return nil
        }
        return quarantine
    }

    nonisolated private static func emptyRemoteSnapshot() -> TranscriptSnapshot {
        TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: "",
            turns: []
        )
    }

    nonisolated private static func transcriptDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = try? fractional.parse(value) {
                return date
            }

            if let date = try? plain.parse(value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(value)"
            )
        }
        return decoder
    }
}
