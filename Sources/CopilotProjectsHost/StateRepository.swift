import Darwin
import Foundation
import CopilotProjectsCore

struct StateRepository: Sendable {
    private final class StorageBox: @unchecked Sendable {
        let lock = NSLock()
        var cachedPrimary: (signature: FileSignature, data: Data)?
    }

    enum LoadResult {
        case missing
        case loaded(PersistedState)
        case recovered(PersistedState, String)
        case failed(String)
    }

    let path: URL
    let backupPath: URL
    let saveObserver: (@Sendable () -> Void)?
    private let box = StorageBox()
    var closeIntentPath: URL { path.appendingPathExtension("closing") }

    struct CloseIntent: Codable {
        var sessionIds: Set<String> = []
        var projectIds: Set<String> = []

        func applying(to state: PersistedState) -> PersistedState {
            var state = state
            state.projects.removeAll { projectIds.contains($0.id) }
            for index in state.projects.indices {
                state.projects[index].sessions.removeAll { sessionIds.contains($0.id) }
            }
            return state
        }
    }

    init(path: URL = Paths.statePath, saveObserver: (@Sendable () -> Void)? = nil) {
        self.path = path
        self.backupPath = path.appendingPathExtension("backup")
        self.saveObserver = saveObserver
    }

    func load() -> LoadResult {
        box.lock.lock()
        defer { box.lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> LoadResult {
        do {
            let intent = try pendingClosesLocked()
            switch loadWorkspaceLocked() {
            case .loaded(let state):
                return .loaded(try normalized(intent.applying(to: state)))
            case .recovered(let state, let message):
                return .recovered(try normalized(intent.applying(to: state)), message)
            case .missing:
                return .missing
            case .failed(let message):
                return .failed(message)
            }
        } catch {
            return .failed("Could not recover accepted session closes at \(closeIntentPath.path): \(error)")
        }
    }

    private func loadWorkspaceLocked() -> LoadResult {
        guard FileManager.default.fileExists(atPath: path.path) else {
            box.cachedPrimary = nil
            guard FileManager.default.fileExists(atPath: backupPath.path) else { return .missing }
            do {
                return .recovered(
                    try decode(Data(contentsOf: backupPath)),
                    "Recovered workspace state from \(backupPath.path) because \(path.path) was missing."
                )
            } catch {
                return .failed(
                    "Workspace state was missing at \(path.path), and its backup was invalid: \(error)"
                )
            }
        }
        do {
            let beforeSignature = Self.fileSignature(atPath: path.path)
            let data = try Data(contentsOf: path)
            let decoded = try decode(data)
            if let beforeSignature,
               Self.fileSignature(atPath: path.path) == beforeSignature {
                box.cachedPrimary = (beforeSignature, data)
            } else {
                box.cachedPrimary = nil
            }
            return .loaded(decoded)
        } catch StateError.unsupportedSchema(let version) {
            box.cachedPrimary = nil
            return .failed(
                "Workspace state schema \(version) is newer than this app supports "
                + "(\(PersistedState.currentSchemaVersion)). The file was left untouched."
            )
        } catch {
            box.cachedPrimary = nil
            do {
                let state = try decode(Data(contentsOf: backupPath))
                return .recovered(
                    state,
                    "Recovered workspace state from \(backupPath.path) because \(path.path) was unreadable: \(error)"
                )
            } catch let backupError {
                return .failed(
                    "Could not load workspace state at \(path.path), and its backup was unavailable or invalid. "
                    + "Original error: \(error). Backup error: \(backupError)"
                )
            }
        }
    }

    func pendingCloses() throws -> CloseIntent {
        box.lock.lock()
        defer { box.lock.unlock() }
        return try pendingClosesLocked()
    }

    private func pendingClosesLocked() throws -> CloseIntent {
        guard FileManager.default.fileExists(atPath: closeIntentPath.path) else {
            return CloseIntent()
        }
        return try JSONDecoder().decode(CloseIntent.self, from: Data(contentsOf: closeIntentPath))
    }

    /// One atomic acceptance point for an entire close action, before images,
    /// tracker commands or workspace rows change. The command markers are not
    /// the journal: a tracker can consume them while a project batch is written.
    func acceptCloses(sessionIds: [String], projectIds: [String] = []) throws {
        box.lock.lock()
        defer { box.lock.unlock() }
        var intent = try pendingClosesLocked()
        intent.sessionIds.formUnion(sessionIds)
        intent.projectIds.formUnion(projectIds)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(intent).write(to: closeIntentPath, options: .atomic)
    }

    /// Called only after all accepted teardown tasks finish. Both recovery
    /// copies must exclude the closed rows before the intent can be forgotten.
    func finishCloses(_ state: PersistedState) throws {
        box.lock.lock()
        defer { box.lock.unlock() }
        guard FileManager.default.fileExists(atPath: closeIntentPath.path) else { return }
        let closedState = try normalized(pendingClosesLocked().applying(to: state))
        try saveLocked(closedState)
        try JSONEncoder().encode(closedState).write(to: backupPath, options: .atomic)
        try FileManager.default.removeItem(at: closeIntentPath)
    }

    func save(_ state: PersistedState) throws {
        saveObserver?()
        box.lock.lock()
        defer { box.lock.unlock() }
        try saveLocked(state)
    }

    private func saveLocked(_ state: PersistedState) throws {
        try validate(state)
        let encoded = try JSONEncoder().encode(state)
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Preserve only a known-good prior file. A corrupt primary must never replace
        // the last usable backup. When the primary file's signature matches the last
        // validated primary write or read from this repository, reuse those validated
        // bytes instead of re-reading and re-decoding `path` on every save.
        let backupBytes: Data?
        if let currentSignature = Self.fileSignature(atPath: path.path),
           let cached = box.cachedPrimary,
           cached.signature == currentSignature {
            backupBytes = cached.data
        } else if let existing = try? Data(contentsOf: path),
                  (try? decode(existing)) != nil {
            backupBytes = existing
        } else {
            backupBytes = nil
        }
        if let backupBytes {
            do {
                try backupBytes.write(to: backupPath, options: .atomic)
            } catch {
                NSLog("copilot-projects: could not update state backup: \(error)")
            }
        }
        let stagingURL = directory.appendingPathComponent(
            ".\(path.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try encoded.write(to: stagingURL)
            let stagedSignature = Self.fileSignature(atPath: stagingURL.path)
            guard Darwin.rename(stagingURL.path, path.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if let stagedSignature {
                box.cachedPrimary = (stagedSignature, encoded)
            } else {
                box.cachedPrimary = nil
            }
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            box.cachedPrimary = nil
            throw error
        }
    }

    private static func fileSignature(atPath path: String) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return FileSignature(attributes: attributes)
    }

    func normalized(_ state: PersistedState) throws -> PersistedState {
        try validate(state)
        var copy = state
        for index in copy.projects.indices {
            let sessions = copy.projects[index].sessions
            if !sessions.contains(where: { $0.id == copy.projects[index].selectedSessionId }) {
                copy.projects[index].selectedSessionId = sessions.first?.id
            }
        }
        if !copy.projects.contains(where: { $0.id == copy.selectedProjectId }) {
            copy.selectedProjectId = copy.projects.first?.id
        }
        copy.schemaVersion = PersistedState.currentSchemaVersion
        return copy
    }

    private func decode(_ data: Data) throws -> PersistedState {
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        guard decoded.schemaVersion <= PersistedState.currentSchemaVersion else {
            throw StateError.unsupportedSchema(decoded.schemaVersion)
        }
        return try normalized(decoded)
    }

    private func validate(_ state: PersistedState) throws {
        let projectIds = state.projects.map(\.id)
        guard Set(projectIds).count == projectIds.count else {
            throw StateError.duplicateProjectId
        }
        let sessionIds = state.projects.flatMap(\.sessions).map(\.id)
        guard Set(sessionIds).count == sessionIds.count else {
            throw StateError.duplicateSessionId
        }
    }

    enum StateError: LocalizedError {
        case unsupportedSchema(Int)
        case duplicateProjectId
        case duplicateSessionId

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return "State schema \(version) is newer than supported schema \(PersistedState.currentSchemaVersion)."
            case .duplicateProjectId:
                return "Workspace state contains duplicate project ids."
            case .duplicateSessionId:
                return "Workspace state contains duplicate session ids."
            }
        }
    }
}
