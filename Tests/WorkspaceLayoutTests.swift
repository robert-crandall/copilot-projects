import AppKit
import SwiftUI
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost
@testable import SwiftTerm

final class WorkspaceLayoutTests: XCTestCase {
    @MainActor
    private final class WorkspaceWindow: NSWindow {
        var responderChanges = 0

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            let previous = firstResponder
            let accepted = super.makeFirstResponder(responder)
            if accepted && firstResponder !== previous { responderChanges += 1 }
            return accepted
        }
    }

    @MainActor
    private final class Navigation: ObservableObject {
        @Published var showsProjects = true
    }

    private struct Workspace: View {
        let model: AppModel
        let input: WorkspaceInputController
        @ObservedObject var navigation: Navigation

        var body: some View {
            RootView(model: model, input: input, showsProjects: $navigation.showsProjects)
        }
    }

    @MainActor
    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor
    private func split(named name: String?, in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.autosaveName == name { return split }
        return view.subviews.lazy.compactMap { self.split(named: name, in: $0) }.first
    }

    @MainActor
    private func projectTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.projectTable(in: $0) }.first
    }

    @MainActor
    private func textEditor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { self.textEditor(in: $0) }.first
    }

    @MainActor
    private func withWorkspace(
        initialSurface: SessionSurface? = nil,
        _ body: (AppModel, Navigation, WorkspaceWindow) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = ["SHELL", "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_SOCKET", "COPILOT_PROJECTS_DTACH"]
        let environment = Dictionary(uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        let splitKeys = ["projects", "sessions"].map { "NSSplitView Subview Frames copilot-projects.\($0)" }
        let preferences = splitKeys.map { UserDefaults.standard.object(forKey: $0) }
        let activationPolicy = NSApp.activationPolicy()
        defer {
            for (key, value) in environment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            for (key, value) in zip(splitKeys, preferences) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            NSApp.setActivationPolicy(activationPolicy)
        }
        NSApp.setActivationPolicy(.prohibited)
        for key in splitKeys { UserDefaults.standard.removeObject(forKey: key) }
        setenv("SHELL", "/bin/cat", 1)
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        setenv("COPILOT_PROJECTS_SOCKET", root.appendingPathComponent("control.sock").path, 1)
        unsetenv("COPILOT_PROJECTS_DTACH")
        guard Paths.dtachExecutable == nil else {
            XCTFail("Layout fixtures must not create persistent dtach sessions")
            return
        }
        let session = Session(title: "Layout fixture", cwd: root.path, preferredSurface: initialSurface)
        let project = Project(name: "Projects", cwd: root.path, sessions: [session], selectedSessionId: session.id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project, Project(name: "Empty", cwd: root.path)], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository, isAppActive: { true },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")))
        defer { model.detachAllClients() }
        model.bootstrapIfNeeded()
        _ = try XCTUnwrap(model.controller(for: session.id))
        let navigation = Navigation()
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Workspace(
            model: model, input: WorkspaceInputController(model: model), navigation: navigation
        ))
        defer {
            _ = window.makeFirstResponder(nil)
            window.contentView = nil
        }
        try await settle(window)
        try await body(model, navigation, window)
    }

    @MainActor
    func testConversationFirstMountKeepsTerminalSizedAndHosted() async throws {
        try await withWorkspace(initialSurface: .conversation) { model, _, window in
            let id = try XCTUnwrap(model.globalSelectedSessionId)
            let controller = try XCTUnwrap(model.activeController)
            let terminal = controller.terminalView
            let host = terminal.superview
            let pid = controller.shellPID
            XCTAssertNil(model.visibleTerminalSessionId)
            XCTAssertTrue(terminal.isHidden)
            XCTAssertGreaterThan(terminal.frame.width, 0)
            XCTAssertGreaterThan(terminal.frame.height, 0)
            XCTAssertGreaterThan(terminal.terminalDimensions.cols, 0)
            XCTAssertGreaterThan(terminal.terminalDimensions.rows, 0)
            XCTAssertEqual(terminal.frame.size, host?.bounds.size)
            window.setContentSize(NSSize(width: 820, height: 520))
            try await settle(window)
            XCTAssertGreaterThan(terminal.frame.width, 400)
            XCTAssertEqual(terminal.frame.size, host?.bounds.size,
                           "The selected hidden terminal must resize with its host")
            XCTAssertGreaterThan(terminal.terminalDimensions.cols, 0)
            model.setSessionSurface(.terminal, sessionId: id)
            try await settle(window)
            XCTAssertFalse(terminal.isHidden)
            XCTAssertTrue(terminal.superview === host)
            XCTAssertTrue(model.activeController === controller)
            XCTAssertEqual(model.activeController?.shellPID, pid)
            model.setSessionSurface(.conversation, sessionId: id)
            try await settle(window)
            XCTAssertTrue(terminal.superview === host)
            XCTAssertEqual(model.activeController?.shellPID, pid)
        }
    }

    @MainActor
    func testBothNavigationPanesResizeAndRespectCompactWindow() async throws {
        try await withWorkspace { model, _, window in
            let root = try XCTUnwrap(window.contentView)
            let projects = try XCTUnwrap(split(named: "copilot-projects.projects", in: root))
            let sessions = try XCTUnwrap(split(named: "copilot-projects.sessions", in: root))
            let terminal = try XCTUnwrap(model.activeController?.terminalView)
            let originalProjectsWidth = projects.subviews[0].frame.width
            XCTAssertEqual(originalProjectsWidth, 176, accuracy: 1)
            projects.setPosition(300, ofDividerAt: 0)
            sessions.setPosition(250, ofDividerAt: 0)
            try await settle(window)
            XCTAssertNotEqual(projects.subviews[0].frame.width, originalProjectsWidth)
            XCTAssertEqual(projects.subviews[0].frame.width, 300, accuracy: 1)
            XCTAssertEqual(sessions.subviews[0].frame.width, 250, accuracy: 1)
            XCTAssertGreaterThanOrEqual(terminal.bounds.width, 420)

            projects.setPosition(100, ofDividerAt: 0)
            try await settle(window)
            XCTAssertEqual(projects.subviews[0].frame.width, 176, accuracy: 1)
            projects.setPosition(500, ofDividerAt: 0)
            try await settle(window)
            XCTAssertEqual(projects.subviews[0].frame.width, 360, accuracy: 1)

            window.setContentSize(NSSize(width: 820, height: 520))
            try await settle(window)
            XCTAssertEqual(root.bounds.width, 820, accuracy: 1)
            XCTAssertGreaterThanOrEqual(projects.subviews[0].frame.width, 176)
            XCTAssertGreaterThanOrEqual(sessions.subviews[0].frame.width, 200)
            XCTAssertGreaterThanOrEqual(terminal.bounds.width, 420)
        }
    }

    @MainActor
    func testCollapseRestoresWidthAndPreservesLiveTerminal() async throws {
        try await withWorkspace { model, navigation, window in
            let root = try XCTUnwrap(window.contentView)
            let projects = try XCTUnwrap(split(named: "copilot-projects.projects", in: root))
            let sessions = try XCTUnwrap(split(named: "copilot-projects.sessions", in: root))
            let controller = try XCTUnwrap(model.activeController)
            let terminal = controller.terminalView
            let container = terminal.superview
            let pid = controller.shellPID
            projects.setPosition(260, ofDividerAt: 0)
            sessions.setPosition(250, ofDividerAt: 0)
            try await settle(window)
            let terminalWidth = terminal.bounds.width
            XCTAssertTrue(window.makeFirstResponder(terminal))
            let responderChanges = window.responderChanges

            navigation.showsProjects = false
            try await settle(window)
            XCTAssertTrue(projects.isSubviewCollapsed(projects.subviews[0]))
            XCTAssertGreaterThan(terminal.bounds.width, terminalWidth)
            XCTAssertTrue(window.firstResponder === terminal)
            XCTAssertEqual(window.responderChanges, responderChanges)
            XCTAssertTrue(terminal.superview === container)

            navigation.showsProjects = true
            try await settle(window)
            XCTAssertFalse(projects.isSubviewCollapsed(projects.subviews[0]))
            XCTAssertEqual(projects.subviews[0].frame.width, 260, accuracy: 1)
            XCTAssertEqual(sessions.subviews[0].frame.width, 250, accuracy: 1)
            XCTAssertTrue(model.activeController?.terminalView === terminal)
            XCTAssertTrue(terminal.superview === container)
            XCTAssertEqual(model.activeController?.shellPID, pid)
            XCTAssertTrue(window.firstResponder === terminal)
            XCTAssertEqual(window.responderChanges, responderChanges)

            navigation.showsProjects = false
            try await settle(window)
            window.setContentSize(NSSize(width: 820, height: 520))
            try await settle(window)
            navigation.showsProjects = true
            try await settle(window)
            XCTAssertEqual(root.bounds.width, 820, accuracy: 1)
            XCTAssertGreaterThanOrEqual(terminal.bounds.width, 420)
            XCTAssertGreaterThanOrEqual(projects.subviews[0].frame.width, 176)
            XCTAssertTrue(terminal.superview === container)
            XCTAssertEqual(model.activeController?.shellPID, pid)
        }

    }

    @MainActor
    func testConversationToggleKeepsTerminalMountedAndDoesNotRefocusIt() async throws {
        try await withWorkspace { model, navigation, window in
            let id = try XCTUnwrap(model.globalSelectedSessionId)
            let controller = try XCTUnwrap(model.activeController)
            let terminal = controller.terminalView
            let container = terminal.superview
            let pid = controller.shellPID
            XCTAssertTrue(window.makeFirstResponder(terminal))
            model.setSessionSurface(.conversation, sessionId: id)
            try await settle(window)
            XCTAssertNotNil(textEditor(in: try XCTUnwrap(window.contentView)),
                            "Conversation mounts an AppKit text editor")
            XCTAssertNil(model.visibleTerminalSessionId)
            XCTAssertTrue(terminal.isHidden)
            XCTAssertFalse(window.firstResponder === terminal)
            XCTAssertTrue(terminal.superview === container)
            let editor = try XCTUnwrap(textEditor(in: try XCTUnwrap(window.contentView)))
            XCTAssertTrue(window.makeFirstResponder(editor))
            navigation.showsProjects = false
            try await settle(window)
            XCTAssertTrue(window.firstResponder === editor, "Hiding Projects must retain composer focus")
            navigation.showsProjects = true
            try await settle(window)
            if let table = projectTable(in: try XCTUnwrap(window.contentView)) {
                XCTAssertTrue(window.makeFirstResponder(table))
                navigation.showsProjects = false
                try await settle(window)
                XCTAssertTrue(window.firstResponder === editor,
                              "Hiding Projects should return focus from its table to the composer")
            }
            navigation.showsProjects = true
            try await settle(window)
            XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(projectTable(in: try XCTUnwrap(window.contentView)))))
            model.focusActiveWorkspace()
            XCTAssertTrue(window.firstResponder === editor, "Activation should focus the visible composer")
            let finder = WorkspaceInputController(model: model)
            XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(projectTable(in: try XCTUnwrap(window.contentView)))))
            finder.openFromSessionFinder(id)
            try await settle(window)
            XCTAssertTrue(window.firstResponder === editor, "Reopening the selected session restores composer focus")
            model.focusActiveTerminal()
            XCTAssertTrue(window.firstResponder === editor, "Terminal-only callbacks cannot steal focus")
            let before = window.responderChanges
            model.focusActiveTerminal()
            XCTAssertEqual(window.responderChanges, before)
            model.setSessionSurface(.terminal, sessionId: id)
            try await settle(window)
            XCTAssertFalse(terminal.isHidden)
            XCTAssertTrue(terminal.superview === container)
            XCTAssertTrue(model.activeController === controller)
            XCTAssertEqual(model.activeController?.shellPID, pid)
        }
    }

    @MainActor
    func testNativeComposerEditingAndCommandReturnUseSDKWithoutTerminalInput() async throws {
        try await withWorkspace { model, _, window in
            let id = try XCTUnwrap(model.globalSelectedSessionId)
            let terminal = try XCTUnwrap(model.activeController?.terminalView)
            let process = try XCTUnwrap(terminal.process)
            let sdkID = UUID().uuidString
            let sessionsDirectory = model.resumeMarkerDirectory
            try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
            try Data(sdkID.utf8).write(to: sessionsDirectory.appendingPathComponent("\(id).copilot-session"))
            let now = Date()
            let snapshot = AgentActivitySnapshot(
                schemaVersion: 1, updatedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
                foregroundTurnActive: false, scheduledTurnActive: false, activeSubagents: [], schedules: [],
                idleGeneration: 0, lastIdleAborted: false, lastIdleTurnKind: nil, error: nil,
                pendingPermissionRequestIds: [], copilotSessionId: sdkID, conversationEpoch: "native-ui",
                operationReceiptVersion: 1, operationReceipts: [],
                workflow: RemoteSessionWorkflow(
                    observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1000),
                    capabilities: ["session-send"], sendReady: true
                )
            )
            try JSONEncoder().encode(snapshot).write(
                to: sessionsDirectory.appendingPathComponent("\(id).agent-activity.json"))
            let transcript = TranscriptSnapshot(
                schemaVersion: 3, updatedAt: now, copilotSessionId: sdkID,
                turns: [TranscriptTurn(
                    id: "turn", startedAt: now, endedAt: now, kind: "user",
                    userContent: "Show me the command to run the focused tests.",
                    assistantMessages: [TranscriptAssistantMessage(
                        id: "reply", timestamp: now,
                        content: "Run the workspace tests:\n\n```sh\nswift test --filter WorkspaceLayoutTests\n```\n\nYour terminal session keeps running when you switch views."
                    )],
                    tools: [TranscriptTool(id: "tool", name: "read", title: "Read test configuration", success: true)],
                    isAborted: false
                )]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(transcript).write(
                to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: id)))
            model.activeTranscriptController?.reload()
            model.refreshAgentActivitySnapshots()
            model.setSessionSurface(.conversation, sessionId: id)
            try await settle(window)
            let editor = try XCTUnwrap(textEditor(in: try XCTUnwrap(window.contentView)))
            XCTAssertEqual(model.activeTranscriptController?.snapshot?.turns.count, 1)
            XCTAssertTrue(window.makeFirstResponder(editor))
            let originalSends = process.sendCount
            let commandReturn = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertTrue(window.performKeyEquivalent(with: commandReturn))
            XCTAssertNil(model.conversationSession(id)?.pendingConversationSend)
            XCTAssertNil(model.conversationErrors[id], "An empty disabled send should be a no-op")
            editor.insertText("first line", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.insertNewline(nil)
            editor.insertText("second line", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await settle(window)
            XCTAssertEqual(model.conversationSession(id)?.conversationDraft, "first line\nsecond line")
            XCTAssertEqual(process.sendCount, originalSends)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            let textType = try XCTUnwrap(editor.writablePasteboardTypes.first)
            pasteboard.declareTypes(editor.writablePasteboardTypes, owner: nil)
            XCTAssertTrue(editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes))
            XCTAssertEqual(pasteboard.string(forType: .string), "first line\nsecond line")
            editor.insertText("", replacementRange: editor.selectedRange())
            XCTAssertTrue(editor.readSelection(from: pasteboard, type: textType))
            try await settle(window)
            XCTAssertEqual(model.conversationSession(id)?.conversationDraft, "first line\nsecond line")
            editor.breakUndoCoalescing()
            editor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.breakUndoCoalescing()
            try await settle(window)
            XCTAssertTrue(editor.allowsUndo)
            XCTAssertTrue(editor.undoManager?.canUndo == true)
            XCTAssertTrue(editor.tryToPerform(NSSelectorFromString("undo:"), with: nil))
            XCTAssertEqual(editor.string, "first line\nsecond line", "Native editor undo")
            try await settle(window)
            XCTAssertEqual(model.conversationSession(id)?.conversationDraft, "first line\nsecond line")
            XCTAssertTrue(editor.tryToPerform(NSSelectorFromString("redo:"), with: nil))
            try await settle(window)
            XCTAssertEqual(model.conversationSession(id)?.conversationDraft, "first line\nsecond line!")
            XCTAssertTrue(editor.tryToPerform(NSSelectorFromString("undo:"), with: nil))
            try await settle(window)

            window.setContentSize(NSSize(width: 820, height: 520))
            try await settle(window)
            XCTAssertGreaterThan(editor.visibleRect.width, 300)
            XCTAssertGreaterThan(editor.visibleRect.height, 50)

            XCTAssertTrue(window.performKeyEquivalent(with: commandReturn))
            try await settle(window)
            let pending = try XCTUnwrap(model.conversationSession(id)?.pendingConversationSend)
            XCTAssertEqual(pending.action.prompt, "first line\nsecond line")
            XCTAssertEqual(process.sendCount, originalSends)
            XCTAssertTrue(editor.isEditable, "A pending send must not prevent drafting the next message")
            editor.insertText(" next", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await settle(window)
            XCTAssertTrue(model.conversationSession(id)?.conversationDraft.contains(" next") == true)
        }
    }

    @MainActor
    func testReopeningRestoresWidthsButNotCollapsedVisibility() async throws {
        try await withWorkspace { model, navigation, window in
            let projects = try XCTUnwrap(split(
                named: "copilot-projects.projects", in: try XCTUnwrap(window.contentView)))
            let sessions = try XCTUnwrap(split(
                named: "copilot-projects.sessions", in: try XCTUnwrap(window.contentView)))
            projects.setPosition(270, ofDividerAt: 0)
            sessions.setPosition(250, ofDividerAt: 0)
            try await settle(window)

            for closedWhileHidden in [false, true] {
                navigation.showsProjects = !closedWhileHidden
                try await settle(window)
                XCTAssertNotNil(UserDefaults.standard.object(
                    forKey: "NSSplitView Subview Frames copilot-projects.projects"))
                window.contentView = nil
                navigation.showsProjects = true
                window.contentView = NSHostingView(rootView: Workspace(
                    model: model, input: WorkspaceInputController(model: model), navigation: navigation
                ))
                try await settle(window)
                let restoredProjects = try XCTUnwrap(split(
                    named: "copilot-projects.projects", in: try XCTUnwrap(window.contentView)))
                let restoredSessions = try XCTUnwrap(split(
                    named: "copilot-projects.sessions", in: try XCTUnwrap(window.contentView)))
                XCTAssertFalse(restoredProjects.isSubviewCollapsed(restoredProjects.subviews[0]))
                XCTAssertEqual(restoredProjects.subviews[0].frame.width, 270, accuracy: 1,
                               "Closed while hidden: \(closedWhileHidden)")
                XCTAssertEqual(restoredSessions.subviews[0].frame.width, 250, accuracy: 1,
                               "Closed while hidden: \(closedWhileHidden)")
            }

            navigation.showsProjects = false
            try await settle(window)
            window.contentView = nil
            window.contentView = NSHostingView(rootView: Workspace(
                model: model, input: WorkspaceInputController(model: model), navigation: navigation
            ))
            try await settle(window)
            let hiddenProjects = try XCTUnwrap(split(
                named: nil, in: try XCTUnwrap(window.contentView)))
            let splitController = try XCTUnwrap(hiddenProjects.delegate as? NSSplitViewController)
            XCTAssertTrue(splitController.splitViewItems[0].isCollapsed)
            navigation.showsProjects = true
            try await settle(window)
            XCTAssertFalse(splitController.splitViewItems[0].isCollapsed)
            XCTAssertEqual(hiddenProjects.subviews[0].frame.width, 270, accuracy: 1)
            let restoredSessions = try XCTUnwrap(split(
                named: "copilot-projects.sessions", in: try XCTUnwrap(window.contentView)))
            XCTAssertEqual(restoredSessions.subviews[0].frame.width, 250, accuracy: 1)
        }
    }

    @MainActor
    func testHidingFocusedProjectsMovesFocusOutOfTheHiddenTable() async throws {
        try await withWorkspace { model, navigation, window in
            for emptyProject in [false, true] {
                if emptyProject {
                    model.selectProject(try XCTUnwrap(model.projects.first { $0.sessions.isEmpty }).id)
                }
                navigation.showsProjects = true
                try await settle(window)
                let table = try XCTUnwrap(projectTable(in: try XCTUnwrap(window.contentView)))
                XCTAssertTrue(window.makeFirstResponder(table))
                navigation.showsProjects = false
                try await settle(window)
                XCTAssertFalse((window.firstResponder as? NSView)?.isDescendant(of: table) ?? false)
                if !emptyProject {
                    XCTAssertTrue(window.firstResponder === model.activeController?.terminalView)
                }
            }
        }
    }
}
