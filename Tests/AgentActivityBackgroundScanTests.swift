import XCTest
@testable import CopilotProjectsHost
import AppKit

/// Reads like `AgentActivityReader.read`, recording where it ran and, when asked,
/// holding the next read after it has read the files and before it returns.
private final class HeldReader: @unchecked Sendable {
    private let lock = NSLock()
    private var holdNext = false
    private var _onMain: [Bool] = []
    private var _returned = 0
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    var onMain: [Bool] { lock.withLock { _onMain } }
    var returned: Int { lock.withLock { _returned } }

    func holdNextRead() { lock.withLock { holdNext = true } }
    func waitUntilHeld() { entered.wait() }
    func release() { gate.signal() }

    var read: AgentActivityReader.Read {
        { [self] sessionIds, directory, cached, clock in
            let hold = lock.withLock { () -> Bool in
                _onMain.append(Thread.isMainThread)
                defer { holdNext = false }
                return holdNext
            }
            let reads = AgentActivityReader.read(sessionIds, directory, cached, clock)
            if hold {
                entered.signal()
                gate.wait()
            }
            lock.withLock { _returned += 1 }
            return reads
        }
    }
}

@MainActor
final class AgentActivityBackgroundScanTests: XCTestCase {
    private var root: URL!
    private var session: Session!
    private var reader: HeldReader!
    private var scans = 0

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        session = Session(title: "background", cwd: root.path)
        reader = HeldReader()
        scans = 0
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        SessionArtifacts.removeFiles(sessionId: session.id)
    }

    private func makeModel() throws -> AppModel {
        let project = Project(name: "background", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        return AppModel(
            stateRepository: repository,
            agentActivityDirectory: root,
            agentActivityScanObserver: { [unowned self] in self.scans += 1 },
            agentActivityReader: reader.read
        )
    }

    private var snapshotURL: URL { root.appendingPathComponent("\(session.id).agent-activity.json") }

    private func publish(generation: Int, scheduled: Bool = false, age: TimeInterval = 0) throws {
        let now = Date().addingTimeInterval(-age)
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let activity = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: now, foregroundTurnActive: false,
            foregroundTransitionAt: now, scheduledTurnActive: scheduled, activeSubagents: [],
            schedules: [], idleGeneration: generation, lastIdleAborted: false,
            lastIdleTurnKind: "foreground", error: nil
        )
        try JSONEncoder().encode(activity).write(to: snapshotURL, options: .atomic)
    }

    private var activity: AgentActivitySnapshot? { modelUnderTest?.projects[0].sessions[0].agentActivity }
    private weak var modelUnderTest: AppModel?

    /// Lets a released read reach the main actor, then a little longer.
    private func settle(afterReads count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while reader.returned < count {
            guard Date() < deadline else { return XCTFail("the read never returned") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    func testWatcherScansReadFilesOffTheMainThread() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        model.scanAgentActivityInBackground()
        XCTAssertEqual(scans, 1)
        XCTAssertNil(activity, "applied only once the read comes back")
        try await settle(afterReads: 1)
        XCTAssertEqual(activity?.idleGeneration, 1)
        XCTAssertEqual(reader.onMain, [false])
    }

    func testAStaleReadNeverOverwritesALaterScan() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        try publish(generation: 2)
        model.refreshAgentActivitySnapshots()
        XCTAssertEqual(activity?.idleGeneration, 2)
        reader.release()
        try await settle(afterReads: 2)
        XCTAssertEqual(activity?.idleGeneration, 2, "the held read saw generation 1 before the later scan")
    }

    func testAStaleReadNeverRestoresASnapshotALaterScanFoundGone() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        try FileManager.default.removeItem(at: snapshotURL)
        model.refreshAgentActivitySnapshots()
        XCTAssertNil(activity)
        reader.release()
        try await settle(afterReads: 2)
        XCTAssertNil(activity, "the held read saw the file before the later scan found it gone")
    }

    func testASnapshotThatExpiresBeforeItsReadIsAppliedIsDropped() async throws {
        try publish(generation: 1, age: 14)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        reader.release()
        try await settle(afterReads: 1)
        XCTAssertNil(activity, "fresh when read, past the 15s limit when applied")
    }

    func testAScheduledTurnThatStartsDuringAReadStaysScheduled() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        // The scheduled-start hook drops its marker and reports while the read is out.
        try Data().write(to: root.appendingPathComponent("\(session.id).scheduled-turn"))
        model.setStatus(
            sessionId: session.id, status: .idle, text: nil,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000), source: "scheduled-start"
        )
        XCTAssertTrue(model.projects[0].sessions[0].scheduledTurnActive)
        reader.release()
        try await settle(afterReads: 1)
        XCTAssertTrue(model.projects[0].sessions[0].scheduledTurnActive, "the marker is checked when applied")
    }

    func testAReadThatFinishesAfterTerminationIsDropped() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        model.scanAgentActivityInBackground()
        model.beginTermination()
        reader.release()
        try await settle(afterReads: 1)
        XCTAssertNil(activity)
        XCTAssertEqual(reader.onMain.count, 1, "no follow-up read after termination")
    }

    func testScansAskedForDuringAReadRunOnceAfterIt() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        try publish(generation: 2)
        model.scanAgentActivityInBackground()
        model.scanAgentActivityInBackground()
        XCTAssertEqual(scans, 3)
        reader.release()
        try await settle(afterReads: 2)
        XCTAssertEqual(reader.onMain, [false, false], "one follow-up for both")
        XCTAssertEqual(activity?.idleGeneration, 2)
    }
}
