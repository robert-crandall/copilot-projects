import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

final class SessionWorkflowTests: XCTestCase {
    @MainActor
    func testLegacySurfaceDefaultsRequireOwnedNonquarantinedCopilotMarker() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try JSONDecoder().decode(Session.self, from: Data(
            #"{"id":"legacy","title":"Copilot","cwd":"/repo"}"#.utf8
        ))
        XCTAssertNil(legacy.preferredSurface)
        XCTAssertEqual(legacy.conversationDraft, "")
        XCTAssertEqual(legacy.draftRevision, 0)
        let plain = Session(id: "plain", title: "shell", cwd: root.path, preferredSurface: .terminal)
        let project = Project(name: "Legacy", cwd: root.path, sessions: [legacy, plain],
                              selectedSessionId: legacy.id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        XCTAssertEqual(model.sessionSurface(sessionId: legacy.id), .terminal,
                       "A title is not owned Copilot metadata")
        let sdkID = UUID().uuidString
        try Data(sdkID.utf8).write(
            to: root.appendingPathComponent("\(legacy.id).copilot-session"))
        XCTAssertEqual(model.sessionSurface(sessionId: legacy.id), .conversation)
        XCTAssertEqual(model.sessionSurface(sessionId: plain.id), .terminal)
        let owner = #"{"appSessionId":"other","copilotSessionId":"\#(sdkID)","pid":1}"#
        try Data(owner.utf8).write(
            to: root.appendingPathComponent("\(legacy.id).transcript-owner.json"))
        XCTAssertEqual(model.sessionSurface(sessionId: legacy.id), .terminal)
        model.setSessionSurface(.conversation, sessionId: legacy.id)
        XCTAssertEqual(model.sessionSurface(sessionId: legacy.id), .conversation,
                       "An explicit choice takes precedence over legacy inference")
    }
    @MainActor
    func testConversationSendPersistsIntentAndReconcilesExactReceiptWithoutLosingEditedDraft() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "Copilot", cwd: root.path, preferredSurface: .conversation)
        let project = Project(name: "Conversation", cwd: root.path, sessions: [session],
                              selectedSessionId: session.id)
        let repository = StateRepository(path: root.appendingPathComponent("state/state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let sdkID = UUID().uuidString
        let snapshotURL = root.appendingPathComponent("\(session.id).agent-activity.json")
        let markerURL = root.appendingPathComponent("\(session.id).copilot-session")
        try Data(sdkID.utf8).write(to: markerURL)
        let now = Date()
        var snapshot = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false, scheduledTurnActive: false, activeSubagents: [], schedules: [],
            idleGeneration: 0, lastIdleAborted: false, lastIdleTurnKind: nil, error: nil,
            pendingPermissionRequestIds: [], copilotSessionId: sdkID,
            conversationEpoch: "epoch-1", operationReceiptVersion: 1, operationReceipts: [],
            workflow: RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1000),
                capabilities: ["session-send"], sendReady: true
            )
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        func makeModel() -> AppModel {
            AppModel(
                stateRepository: repository, isAppActive: { false },
                agentActivityDirectory: root, resumeMarkerDirectory: root,
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
            )
        }
        var model = makeModel()
        model.setConversationDraft("A", sessionId: session.id)
        XCTAssertEqual(model.conversationSession(session.id)?.draftRevision, 1)
        model.setConversationDraft("B", sessionId: session.id)
        model.setConversationDraft("A", sessionId: session.id)
        XCTAssertEqual(model.conversationSession(session.id)?.draftRevision, 3)
        XCTAssertTrue(model.sendConversationDraft(sessionId: session.id, mode: .immediate))
        let pending = try XCTUnwrap(model.conversationSession(session.id)?.pendingConversationSend)
        XCTAssertEqual(pending.action.prompt, "A")
        XCTAssertEqual(pending.action.mode, .immediate)
        XCTAssertEqual(pending.draftRevision, 3)
        let handoff = root.appendingPathComponent("\(session.id).session-send.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: handoff.path))
        XCTAssertFalse(model.sendConversationDraft(sessionId: session.id, mode: .enqueue))
        if case .loaded(let state) = repository.load() {
            XCTAssertEqual(state.projects[0].sessions[0].pendingConversationSend, pending)
        } else {
            XCTFail("The send intent must be durable before handoff")
        }
        model = makeModel()
        XCTAssertEqual(model.conversationSession(session.id)?.pendingConversationSend, pending)
        model.setConversationDraft("B", sessionId: session.id)
        model.setConversationDraft("A", sessionId: session.id)
        XCTAssertEqual(model.conversationSession(session.id)?.draftRevision, 5)
        let fingerprint = try XCTUnwrap(CLIOperationAdapter.payloadFingerprint(
            kind: .sessionSend, payload: pending.action
        ))
        func receipt(_ state: RemoteOperationState, epoch: String = "epoch-1",
                     fingerprint recorded: String? = nil) -> TrackedOperationReceipt {
            TrackedOperationReceipt(
                operationId: pending.operationId, conversationEpoch: epoch,
                kind: CLISDKOperationKind.sessionSend.rawValue, state: state,
                updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
                errorCode: nil, payloadFingerprint: recorded ?? fingerprint
            )
        }
        snapshot.operationReceipts = [receipt(.applied, epoch: "epoch-other")]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        model.reconcileConversationSend(sessionId: session.id)
        XCTAssertNotNil(model.conversationSession(session.id)?.pendingConversationSend)
        snapshot.operationReceipts = [receipt(.applied, fingerprint: "wrong")]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        model.reconcileConversationSend(sessionId: session.id)
        XCTAssertTrue(model.conversationSession(session.id)?.pendingConversationSend?.uncertain == true)
        XCTAssertFalse(model.sendConversationDraft(sessionId: session.id, mode: .enqueue))
        snapshot.operationReceipts = [receipt(.applied)]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        model.reconcileConversationSend(sessionId: session.id)
        XCTAssertNil(model.conversationSession(session.id)?.pendingConversationSend)
        XCTAssertEqual(model.conversationSession(session.id)?.conversationDraft, "A",
                       "A -> B -> A changed the draft revision while the send was pending")
        model = makeModel()
        XCTAssertEqual(model.conversationSession(session.id)?.conversationDraft, "A")
        try FileManager.default.removeItem(at: handoff)
        snapshot.operationReceipts = []
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertTrue(model.sendConversationDraft(sessionId: session.id, mode: .enqueue))
        let next = try XCTUnwrap(model.conversationSession(session.id)?.pendingConversationSend)
        let nextFingerprint = try XCTUnwrap(CLIOperationAdapter.payloadFingerprint(
            kind: .sessionSend, payload: next.action
        ))
        snapshot.operationReceipts = [TrackedOperationReceipt(
            operationId: next.operationId, conversationEpoch: next.conversationEpoch,
            kind: CLISDKOperationKind.sessionSend.rawValue, state: .rejected,
            updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
            errorCode: nil, payloadFingerprint: nextFingerprint
        )]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        model.reconcileConversationSend(sessionId: session.id)
        XCTAssertNil(model.conversationSession(session.id)?.pendingConversationSend)
        XCTAssertEqual(model.conversationSession(session.id)?.conversationDraft, "A")
        try FileManager.default.removeItem(at: handoff)
        snapshot.operationReceipts = []
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertTrue(model.sendConversationDraft(sessionId: session.id, mode: .enqueue))
        let final = try XCTUnwrap(model.conversationSession(session.id)?.pendingConversationSend)
        let finalFingerprint = try XCTUnwrap(CLIOperationAdapter.payloadFingerprint(
            kind: .sessionSend, payload: final.action
        ))
        snapshot.operationReceipts = [TrackedOperationReceipt(
            operationId: final.operationId, conversationEpoch: final.conversationEpoch,
            kind: CLISDKOperationKind.sessionSend.rawValue, state: .accepted,
            updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
            errorCode: nil, payloadFingerprint: finalFingerprint
        )]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        model.reconcileConversationSend(sessionId: session.id)
        XCTAssertNotNil(model.conversationSession(session.id)?.pendingConversationSend)
        snapshot.operationReceipts = [TrackedOperationReceipt(
            operationId: final.operationId, conversationEpoch: final.conversationEpoch,
            kind: CLISDKOperationKind.sessionSend.rawValue, state: .applied,
            updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000) + 1,
            errorCode: nil, payloadFingerprint: finalFingerprint
        )]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        model.reconcileConversationSend(sessionId: session.id)
        XCTAssertNil(model.conversationSession(session.id)?.pendingConversationSend)
        XCTAssertEqual(model.conversationSession(session.id)?.conversationDraft, "")
        model = makeModel()
        XCTAssertEqual(model.conversationSession(session.id)?.conversationDraft, "")
    }

    @MainActor
    func testConversationPersistenceFailurePreventsHandoffAndUncertainUnlockNeedsTerminalInspection() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sdkID = UUID().uuidString
        let session = Session(title: "Copilot", cwd: root.path, preferredSurface: .conversation)
        let project = Project(name: "Conversation", cwd: root.path, sessions: [session],
                              selectedSessionId: session.id)
        let repository = StateRepository(path: root.appendingPathComponent("state/state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        var model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        let now = Date()
        var snapshot = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false, scheduledTurnActive: false, activeSubagents: [], schedules: [],
            idleGeneration: 0, lastIdleAborted: false, lastIdleTurnKind: nil, error: nil,
            pendingPermissionRequestIds: [], copilotSessionId: sdkID,
            conversationEpoch: "epoch-1", operationReceiptVersion: 1, operationReceipts: [],
            workflow: RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1000),
                capabilities: ["session-send"], sendReady: true
            )
        )
        snapshot.pendingPermissionRequestIds = ["permission"]
        try JSONEncoder().encode(snapshot).write(
            to: root.appendingPathComponent("\(session.id).agent-activity.json"))
        try Data(sdkID.utf8).write(
            to: root.appendingPathComponent("\(session.id).copilot-session"))
        model.setConversationDraft("keep me", sessionId: session.id)
        XCTAssertFalse(model.sendConversationDraft(sessionId: session.id, mode: .enqueue))
        XCTAssertNil(model.conversationSession(session.id)?.pendingConversationSend,
                     "A locally rejected send must not require uncertain-delivery recovery")
        snapshot.pendingPermissionRequestIds = []
        try JSONEncoder().encode(snapshot).write(
            to: root.appendingPathComponent("\(session.id).agent-activity.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("state"))
        try Data("blocked".utf8).write(to: root.appendingPathComponent("state"))
        XCTAssertFalse(model.sendConversationDraft(sessionId: session.id, mode: .enqueue))
        XCTAssertNil(model.conversationSession(session.id)?.pendingConversationSend)
        XCTAssertEqual(model.conversationSession(session.id)?.conversationDraft, "keep me")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("\(session.id).session-send.json").path))
        XCTAssertNotNil(model.conversationErrors[session.id])
        try FileManager.default.removeItem(at: root.appendingPathComponent("state"))
        XCTAssertTrue(model.sendConversationDraft(sessionId: session.id, mode: .enqueue))
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("\(session.id).session-send.json"))
        model.reconcileConversationSend(sessionId: session.id)
        XCTAssertTrue(model.conversationSession(session.id)?.pendingConversationSend?.uncertain == true)
        model.unlockConversationSendAfterInspection(sessionId: session.id)
        XCTAssertNotNil(model.conversationSession(session.id)?.pendingConversationSend)
        model.setSessionSurface(.terminal, sessionId: session.id)
        model.unlockConversationSendAfterInspection(sessionId: session.id)
        XCTAssertNil(model.conversationSession(session.id)?.pendingConversationSend)
        XCTAssertEqual(model.conversationSession(session.id)?.conversationDraft, "keep me")
        XCTAssertEqual(model.sessionSurface(sessionId: session.id), .terminal)
        model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        XCTAssertNil(model.conversationSession(session.id)?.pendingConversationSend)
        XCTAssertEqual(model.conversationSession(session.id)?.conversationDraft, "keep me")
    }
    func testActionValidationIsClosedAndBudgetLimitsAreExplicit() throws {
        XCTAssertTrue(RemoteSessionAction(kind: .send, prompt: "hello", mode: .enqueue).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .send, prompt: "hello").isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .abort, prompt: "unexpected").isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .setBudget, maxAiCredits: 29).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .setBudget, maxAiCredits: .infinity).isValid)
        XCTAssertTrue(RemoteSessionAction(kind: .setBudget, maxAiCredits: 30).isValid)
        XCTAssertTrue(RemoteSessionAction(kind: .setBudget).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .answerBudget, requestId: "id", additionalAiCredits: 0).isValid)
        XCTAssertTrue(RemoteSessionAction(kind: .answerBudget, requestId: "id").isValid)
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteSessionAction.self, from: Data(#"{"kind":"arbitrary-rpc"}"#.utf8)
        ))
    }

    func testWorkflowCapabilityRequiresCurrentVersionAndFreshEvidence() {
        let date = Date()
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(date.timeIntervalSince1970 * 1000),
            capabilities: ["session-send"], sendReady: true
        )
        XCTAssertTrue(workflow.supports(.send, at: date))
        XCTAssertFalse(workflow.supports(.abort, at: date))
        XCTAssertFalse(workflow.supports(.send, at: date.addingTimeInterval(16)))
        XCTAssertFalse(workflow.supports(.send, at: date.addingTimeInterval(-1)))
    }

    func testRemoteFreshnessAgesFromServeTimeOnTheClientsOwnClock() {
        let observedAt: Int64 = 1_787_788_800_000
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: observedAt,
            capabilities: ["session-send"], sendReady: true
        )
        let receivedAt = ContinuousClock.now
        // The phone's wall clock is a minute behind the Mac, which the wall-clock
        // rule reads as an observation from the future.
        let skewedPhone = Date(timeIntervalSince1970: Double(observedAt - 60_000) / 1_000)
        XCTAssertFalse(workflow.isFresh(at: skewedPhone))
        XCTAssertTrue(workflow.supports(
            .send, servedAtMilliseconds: observedAt + 4_000, receivedAt: receivedAt,
            now: receivedAt.advanced(by: .seconds(11)), at: skewedPhone
        ))
        XCTAssertFalse(workflow.supports(
            .send, servedAtMilliseconds: observedAt + 4_000, receivedAt: receivedAt,
            now: receivedAt.advanced(by: .milliseconds(11_001)), at: skewedPhone
        ))
        // Sub-millisecond monotonic time still counts toward the limit.
        XCTAssertEqual(
            workflow.ageMilliseconds(
                servedAtMilliseconds: observedAt + 4_000, receivedAt: receivedAt,
                now: receivedAt.advanced(by: .microseconds(10_999_500))
            ),
            14_999.5
        )
        // Defaults read the current clocks: a just-received snapshot is fresh.
        XCTAssertTrue(workflow.isFresh(
            servedAtMilliseconds: observedAt, receivedAt: .now
        ))
        let current = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: ["session-send"], sendReady: true
        )
        XCTAssertTrue(current.isFresh(servedAtMilliseconds: nil, receivedAt: .now))
    }

    @MainActor
    func testNativeHostActionsUseDistinctHandoffsAndNeverInjectTerminalInput() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let session = Session(title: "Native actions", cwd: root.path)
        let project = Project(name: "Workflow test", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository, persistPermissionStatus: { _, _, _, _ in },
            isAppActive: { false }, agentActivityDirectory: sessions, resumeMarkerDirectory: sessions,
            remotePromptTarget: { _ in
                RemotePromptTarget(activity: .idle, send: { _ in
                    XCTFail("Native actions must not touch the terminal draft")
                    return false
                })
            },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        let now = Date()
        let sdkID = UUID().uuidString
        var snapshot = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false, scheduledTurnActive: false, activeSubagents: [], schedules: [],
            idleGeneration: 0, lastIdleAborted: false, lastIdleTurnKind: nil, error: nil,
            pendingPermissionRequestIds: [], copilotSessionId: sdkID,
            conversationEpoch: "epoch-1", operationReceiptVersion: 1, operationReceipts: [],
            workflow: RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1000),
                capabilities: RemoteSessionActionKind.allCases.map(\.rawValue), sendReady: true,
                limitsKnown: true
            )
        )
        let snapshotURL = sessions.appendingPathComponent("\(session.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        try Data(sdkID.utf8).write(to: sessions.appendingPathComponent("\(session.id).copilot-session"))
        let send = RemoteSessionAction(kind: .send, prompt: "native", mode: .immediate)
        let sendID = CLIOperationRequest(operationId: "send", conversationEpoch: "epoch-1")
        XCTAssertEqual(model.performSessionAction(sessionId: session.id, action: send, operation: sendID), .accepted)
        XCTAssertEqual(model.performSessionAction(sessionId: session.id, action: send, operation: sendID), .accepted)
        let stop = RemoteSessionAction(kind: .abort)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: stop,
            operation: CLIOperationRequest(operationId: "stop", conversationEpoch: "epoch-1")
        ), .accepted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("\(session.id).session-send.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("\(session.id).session-abort.json").path))
        XCTAssertEqual(model.performSessionAction(sessionId: session.id, action: stop, operation: sendID), .conflict)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: send,
            operation: CLIOperationRequest(operationId: "old", conversationEpoch: "epoch-0")
        ), .conflict)
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(session.id).session-send.json"))
        snapshot.pendingPermissionRequestIds = ["pending"]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: send,
            operation: CLIOperationRequest(operationId: "blocked", conversationEpoch: "epoch-1")
        ), .invalid)
    }
}
