import AppKit
import Combine
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsHost

@MainActor
final class ProjectInstructionsTests: XCTestCase {
    private var root: URL!
    private var store: ProjectInstructionsStore!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectInstructionsStore(root: root.appendingPathComponent("project-instructions"))
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: root)
    }

    private func instructionFile(_ directory: URL) -> URL {
        directory.appendingPathComponent(".github/instructions/copilot-projects.instructions.md")
    }

    func testSaveReopenClearAndProjectIsolation() throws {
        XCTAssertEqual(try store.read(projectId: "first"), "")
        let body = "  Prefer focused changes.\n\n---\nKeep this markdown.\n"
        try store.save(body, projectId: "first")
        try store.save("Second project", projectId: "second")
        let reopened = ProjectInstructionsStore(root: store.root)
        XCTAssertEqual(try reopened.read(projectId: "first"), body)
        XCTAssertEqual(try reopened.read(projectId: "second"), "Second project")
        XCTAssertEqual(
            try String(contentsOf: instructionFile(store.projectDirectory("first")), encoding: .utf8),
            "---\napplyTo: \"**\"\n---\n" + body
        )
        try reopened.save(" \n\t", projectId: "first")
        try reopened.save("", projectId: "first")
        XCTAssertEqual(try reopened.read(projectId: "first"), "")
        XCTAssertEqual(try reopened.read(projectId: "second"), "Second project")
    }

    func testReadAndWriteErrorsDoNotBecomeEmptySuccess() throws {
        try store.save("original", projectId: "project")
        let file = instructionFile(store.projectDirectory("project"))
        try Data([0xff]).write(to: file)
        XCTAssertThrowsError(try store.read(projectId: "project"))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.save("replacement", projectId: "project"))
        XCTAssertThrowsError(try store.read(projectId: "../escape"))
        let unsupported = ProjectInstructionsStore(root: root.appendingPathComponent("has,comma"))
        XCTAssertFalse(unsupported.supportsCustomInstructions)
        XCTAssertThrowsError(try unsupported.save("instructions", projectId: "project"))
    }

    func testSessionLinkTracksEditsMovesAndClearWithoutChangingPath() throws {
        try store.link(sessionId: "session", projectId: "first")
        try store.link(sessionId: "session", projectId: "first")
        let file = instructionFile(store.sessionDirectory("session"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try store.save("First project", projectId: "first")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("First project"))
        try store.save("Updated", projectId: "first")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("Updated"))
        try store.save("Second project", projectId: "second")
        try store.link(sessionId: "session", projectId: "second")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), ProjectInstructionsStore.header + "Second project")
        try store.save("", projectId: "second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try store.read(projectId: "first"), "Updated")
    }

    func testEnvironmentPreservesUserDirectoriesAndRemovesOnlyInheritedAppEntry() {
        let key = ProjectInstructionsStore.environmentKey
        let marker = ProjectInstructionsStore.sessionDirectoryKey
        let base = [key: "/user/one,/old session,/user/two,/old session-other",
                    marker: "/old session", "PATH": "/usr/bin"]
        let result = ProjectInstructionsStore.environment(from: base, sessionDirectory: "/new session")
        XCTAssertEqual(result[key], "/user/one,/user/two,/old session-other,/new session")
        XCTAssertEqual(result[marker], "/new session")
        XCTAssertEqual(result["PATH"], "/usr/bin")
        XCTAssertEqual(ProjectInstructionsStore.environment(from: result, sessionDirectory: "/new session"), result)
        XCTAssertEqual(
            ProjectInstructionsStore.environment(from: result, sessionDirectory: nil)[key],
            "/user/one,/user/two,/old session-other"
        )
        XCTAssertTrue(ProjectInstructionsStore.environment(from: [key: "/old", marker: "/old"],
                                                          sessionDirectory: nil).isEmpty)
        XCTAssertEqual(ProjectInstructionsStore.environment(from: [:], sessionDirectory: "/new")[key], "/new")
    }

    private func model(
        otherSessions: [Session] = [],
        present: @escaping (NSAlert) -> NSApplication.ModalResponse = { _ in .alertSecondButtonReturn }
    ) throws -> AppModel {
        let session = Session(id: "session", title: "Session", cwd: root.path)
        let projects = [
            Project(id: "first", name: "Same name", cwd: root.path, sessions: [session]),
            Project(id: "second", name: "Same name", cwd: root.path, sessions: otherSessions),
        ]
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: projects, selectedProjectId: "second"))
        return AppModel(
            stateRepository: repository, agentActivityDirectory: root, resumeMarkerDirectory: root,
            remoteCopilotExecutable: { "/fake/copilot" }, remoteSessionBackendAvailable: { true },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            forcedSessionDestroyer: { _ in }, alertPresenter: present
        )
    }

    func testStartupRepairsUnselectedSessionAndMovePersistsNewOwner() throws {
        let model = try model()
        try store.save("First", projectId: "first")
        try store.save("Second", projectId: "second")
        try store.link(sessionId: "session", projectId: "second")
        model.finishInterruptedSessionDestroys()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: store.sessionDirectory("session").path), store.projectDirectory("first").path)
        XCTAssertTrue(model.hostedTerminals.isEmpty)
        XCTAssertTrue(model.moveSession(toProjectId: "second", draggedId: "session"))
        XCTAssertEqual(try String(contentsOf: instructionFile(store.sessionDirectory("session")), encoding: .utf8),
                       ProjectInstructionsStore.header + "Second")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        guard case .loaded(let saved) = repository.load() else { return XCTFail("State was not saved") }
        XCTAssertEqual(saved.projects[1].sessions.first?.id, "session")
        model.renameProject("second", name: "Renamed")
        XCTAssertEqual(try store.read(projectId: "second"), "Second")
    }

    func testFailedMoveRestoresOwnershipAndInstructionLink() throws {
        var errors = 0
        let model = try model { alert in
            XCTAssertEqual(alert.messageText, "Could Not Move Session")
            errors += 1
            return .alertFirstButtonReturn
        }
        try store.link(sessionId: "session", projectId: "first")
        let state = root.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        XCTAssertFalse(model.moveSession(toProjectId: "second", draggedId: "session"))
        XCTAssertEqual(model.projects[0].sessions.first?.id, "session")
        XCTAssertTrue(model.projects[1].sessions.isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: store.sessionDirectory("session").path), store.projectDirectory("first").path)
        XCTAssertEqual(errors, 1)
    }

    func testLinkFailureRejectsMoveWithoutChangingOwnership() throws {
        let model = try model()
        let path = store.sessionDirectory("session")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertFalse(model.moveSession(toProjectId: "second", draggedId: "session"))
        XCTAssertEqual(model.projects[0].sessions.first?.id, "session")
        XCTAssertTrue(model.projects[1].sessions.isEmpty)
    }

    func testInstructionFailureDoesNotBlockWorkspaceRecoveryOrShowModalAlerts() throws {
        let model = try model(otherSessions: [Session(id: "healthy", title: "Healthy", cwd: root.path)]) { _ in
            XCTFail("Non-interactive paths must not open a modal")
            return .alertFirstButtonReturn
        }
        try FileManager.default.createDirectory(
            at: store.sessionDirectory("session"), withIntermediateDirectories: true)
        model.finishInterruptedSessionDestroys()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: store.sessionDirectory("healthy").path), store.projectDirectory("second").path)
        model.renameProject("second", name: "Still saves")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        guard case .loaded(let saved) = repository.load() else { return XCTFail("Workspace failed to save") }
        XCTAssertEqual(saved.projects[1].name, "Still saves")
        XCTAssertNil(model.controller(for: "session"))
        XCTAssertNil(model.controller(for: "session"))
        model.selectProject("first")
        XCTAssertTrue(model.emptyContextHint.message.contains("Could not load project instructions"))
        XCTAssertEqual(model.emptyContextHint.button, "Retry")
        var updates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        model.newInActiveContext()
        observation.cancel()
        XCTAssertEqual(updates, 1, "Retry must refresh the terminal container even though controllers are not observed")
        XCTAssertEqual(model.moveRemoteSession(sessionId: "session", toProjectId: "second"), .missing)
        XCTAssertEqual(model.projects[0].sessions.first?.id, "session")
    }

    func testExplicitLaunchDoesNotKeepAnUnstartedSessionAfterInstructionFailure() throws {
        let model = try model { _ in XCTFail("Launch must return an error without a nested modal"); return .alertFirstButtonReturn }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try "blocked".write(to: store.root.appendingPathComponent("sessions"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try model.addCopilotSession(toProjectId: "first", initialPrompt: "Keep this request"))
        XCTAssertEqual(model.projects[0].sessions.map(\.id), ["session"])
        XCTAssertTrue(model.hostedTerminals.isEmpty)
    }

    func testFailedStateLoadLeavesInstructionFilesAndLinksUntouched() throws {
        try store.save("Keep me", projectId: "first")
        try store.link(sessionId: "session", projectId: "first")
        let state = root.appendingPathComponent("state.json")
        try "invalid".write(to: state, atomically: true, encoding: .utf8)
        let model = AppModel(stateRepository: StateRepository(path: state), agentActivityDirectory: root)
        model.finishInterruptedSessionDestroys()
        XCTAssertEqual(try store.read(projectId: "first"), "Keep me")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: store.sessionDirectory("session").path), store.projectDirectory("first").path)
    }

    func testCloseJournalCleansOnlyEndedProjectAndSession() throws {
        let model = try model()
        try store.save("First", projectId: "first")
        try store.save("Second", projectId: "second")
        try store.link(sessionId: "session", projectId: "first")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.acceptCloses(sessionIds: ["session"], projectIds: ["first"])
        model.finishInterruptedSessionDestroys()
        XCTAssertNil(model.project("first"))
        XCTAssertEqual(try store.read(projectId: "first"), "")
        XCTAssertEqual(try store.read(projectId: "second"), "Second")
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(
            atPath: store.sessionDirectory("session").path))
        XCTAssertTrue(try repository.pendingCloses().projectIds.isEmpty)
    }

    func testEditorCancelRetryAndEmptySave() throws {
        let editor = ProjectInstructionsEditor(projectName: "Project", text: "  Original\n---\n")
        XCTAssertFalse(editor.textView.isRichText)
        XCTAssertTrue(editor.alert.window.initialFirstResponder === editor.textView)
        XCTAssertEqual(editor.alert.buttons[0].keyEquivalentModifierMask, .command)
        XCTAssertEqual(editor.alert.buttons[1].keyEquivalent, "\u{1b}")
        editor.run(present: { _ in .alertSecondButtonReturn }) { _ in XCTFail("Cancelled") }
        var attempts = 0
        editor.run(present: { alert in
            XCTAssertEqual(editor.textView.string, "  Original\n---\n")
            if attempts > 0 { XCTAssertTrue(alert.informativeText.contains("Could not save instructions")) }
            return attempts < 2 ? .alertFirstButtonReturn : .alertSecondButtonReturn
        }) { text in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileWriteNoPermission) }
            try store.save(text, projectId: "project")
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(try store.read(projectId: "project"), "  Original\n---\n")
        editor.textView.string = ""
        XCTAssertTrue(editor.alert.buttons[0].isEnabled)
        editor.run(present: { _ in .alertFirstButtonReturn }) { try store.save($0, projectId: "project") }
        XCTAssertEqual(try store.read(projectId: "project"), "")
    }

    func testProjectEditorSavesOnlyItsNamedProject() throws {
        let model = try model { alert in
            let scroll = try! XCTUnwrap(alert.accessoryView as? NSScrollView)
            let text = try! XCTUnwrap(scroll.documentView as? NSTextView)
            text.string = "Only first"
            return .alertFirstButtonReturn
        }
        model.editProjectInstructionsInteractive("first")
        XCTAssertEqual(try store.read(projectId: "first"), "Only first")
        XCTAssertEqual(try store.read(projectId: "second"), "")
    }

    func testEditorDoesNotResaveAfterProjectClosesOrTerminationStarts() {
        let editor = ProjectInstructionsEditor(projectName: "Project", text: "Keep my draft")
        var presentations = 0
        editor.run(present: { alert in
            presentations += 1
            if presentations == 1 { return .alertFirstButtonReturn }
            XCTAssertFalse(alert.buttons[0].isEnabled)
            XCTAssertEqual(editor.textView.string, "Keep my draft")
            return .alertSecondButtonReturn
        }) { _ in throw AppModel.CopilotSessionStartError.projectUnavailable }
        XCTAssertEqual(presentations, 2)

        var terminating = false
        editor.run(present: { _ in
            terminating = true
            return .alertFirstButtonReturn
        }, isTerminating: { terminating }) { _ in XCTFail("Must not save while terminating") }
    }

    func testControllerPassesAdditiveEnvironmentForFreshResumeAndPlainTerminals() async throws {
        let capture = root.appendingPathComponent("environment")
        let executable = root.appendingPathComponent("capture")
        try """
        #!/bin/sh
        /usr/bin/env > '\(capture.path).tmp'
        /bin/mv '\(capture.path).tmp' '\(capture.path)'
        exec /bin/sleep 30
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let overrides = ["COPILOT_PROJECTS_DTACH": executable.path, "SHELL": executable.path,
                         "COPILOT_CUSTOM_INSTRUCTIONS_DIRS": "/user,/parent",
                         "COPILOT_PROJECTS_INSTRUCTIONS_DIR": "/parent"]
        let previous = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in overrides { setenv(key, value, 1) }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        for mode in ["fresh", "resume", "plain", "fallback"] {
            let model = try model()
            defer { model.detachAllClients() }
            if mode == "fallback" { setenv("COPILOT_PROJECTS_DTACH", "/missing", 1) }
            let controller = try XCTUnwrap(model.controller(
                for: "session",
                copilotExecutable: mode == "fresh" ? "/fake/copilot" : nil,
                resumeCopilotSessionId: mode == "resume" ? UUID().uuidString : nil
            ))
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: capture.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let environment = try String(contentsOf: capture, encoding: .utf8)
            XCTAssertTrue(environment.contains(
                "COPILOT_CUSTOM_INSTRUCTIONS_DIRS=/user,\(store.sessionDirectory("session").path)\n"), mode)
            XCTAssertFalse(environment.contains("/parent"), mode)
            controller.terminate()
            try FileManager.default.removeItem(at: capture)
        }
    }
}
