import XCTest
@testable import CopilotProjectsCore
#if canImport(Darwin)
import Darwin
#endif

final class CoreLogicTests: XCTestCase {
    func testNormalizedDirectoryDecodesFileURL() {
        XCTAssertEqual(
            Paths.normalizedDirectory("file://localhost/Users/example/My%20Project"),
            "/Users/example/My Project"
        )
        XCTAssertEqual(Paths.normalizedDirectory("/tmp/plain"), "/tmp/plain")
    }

    func testSuppressSigPipeReturnsEPIPEAfterPeerCloses() {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer {
            if sockets[0] >= 0 { close(sockets[0]) }
            if sockets[1] >= 0 { close(sockets[1]) }
        }
        XCTAssertTrue(SocketOptions.suppressSigPipe(on: sockets[0]))
        close(sockets[1])
        sockets[1] = -1

        var byte: UInt8 = 1
        let result = withUnsafeBytes(of: &byte) {
            Darwin.write(sockets[0], $0.baseAddress, $0.count)
        }
        XCTAssertEqual(result, -1)
        XCTAssertEqual(errno, EPIPE)
    }

    func testCLIFlagParsing() {
        let parsed = CLIMain.parseFlags([
            "--project=abc", "--session", "def", "first", "--", "--literal",
        ])
        XCTAssertEqual(parsed.flags["project"], "abc")
        XCTAssertEqual(parsed.flags["session"], "def")
        XCTAssertEqual(parsed.positionals, ["first", "--literal"])
    }

    func testCocoaLaunchArgumentsAreAcceptedButUnknownCLIFlagsAreNot() {
        XCTAssertTrue(CLIMain.isCocoaLaunchArguments([
            "-NSDocumentRevisionsDebugMode", "YES", "-psn_0_12345",
        ]))
        XCTAssertTrue(CLIMain.isCocoaLaunchArguments([
            "-ApplePersistenceIgnoreState", "YES",
        ]))
        XCTAssertFalse(CLIMain.isCocoaLaunchArguments(["--unknown"]))
        XCTAssertFalse(CLIMain.isCocoaLaunchArguments(["unknown-command"]))
    }

    func testDtachMasterSelectionIgnoresAttachedClient() {
        let socket = "/tmp/session.sock"
        let processes = [
            ProcessTree.DtachProcess(
                pid: 101, parentPID: 999, socketPath: socket, isMaster: false),
            ProcessTree.DtachProcess(
                pid: 202, parentPID: 101, socketPath: socket, isMaster: false),
        ]
        XCTAssertEqual(ProcessTree.dtachMaster(forSocket: socket, among: processes), 202)
    }

    func testDetachedDtachMasterSelectionUsesLaunchdParent() {
        let socket = "/tmp/session.sock"
        let processes = [
            ProcessTree.DtachProcess(
                pid: 101, parentPID: 999, socketPath: socket, isMaster: false),
            ProcessTree.DtachProcess(
                pid: 202, parentPID: 1, socketPath: socket, isMaster: false),
        ]
        XCTAssertEqual(ProcessTree.dtachMaster(forSocket: socket, among: processes), 202)
    }

    func testProjectInstructionsFileHasApplyToFrontmatter() {
        let contents = ProjectInstructions.fileContents("  Always run swift build.  ")
        XCTAssertTrue(contents.hasPrefix("---\napplyTo: \"**\"\n---\n"))
        XCTAssertTrue(contents.contains("Always run swift build."))
        // Body is trimmed and newline-terminated.
        XCTAssertTrue(contents.hasSuffix("Always run swift build.\n"))
    }

    func testSyncSessionWritesAndRemovesDeliveryFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = UUID().uuidString
        let file = ProjectInstructions.sessionInstructionsFile(sessionId: sessionId, stateDir: root)
        let expectedRoot = ProjectInstructions.sessionRoot(sessionId: sessionId, stateDir: root)

        // Non-empty → writes the delivery file (with frontmatter) and always returns
        // the advertised session root.
        let dir = ProjectInstructions.syncSession(
            sessionId: sessionId, instructions: "Prefer tabs.", stateDir: root)
        XCTAssertEqual(dir, expectedRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(written.contains("applyTo: \"**\""))
        XCTAssertTrue(written.contains("Prefer tabs."))

        // Empty → removes the file but still returns the root (it stays advertised so
        // instructions saved into an already-open session are picked up next launch).
        let cleared = ProjectInstructions.syncSession(
            sessionId: sessionId, instructions: "   ", stateDir: root)
        XCTAssertEqual(cleared, expectedRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testProjectBackupRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectId = UUID().uuidString
        // Missing → nil.
        XCTAssertNil(ProjectInstructions.readProjectBackup(projectId: projectId, stateDir: root))

        // Backup is plain text, so any body (including one containing "---") round-trips.
        let original = "Line one.\n---\nLine two."
        ProjectInstructions.syncProjectBackup(projectId: projectId, instructions: original, stateDir: root)
        XCTAssertEqual(
            ProjectInstructions.readProjectBackup(projectId: projectId, stateDir: root),
            original
        )

        // Cleared → nil again.
        ProjectInstructions.syncProjectBackup(projectId: projectId, instructions: "", stateDir: root)
        XCTAssertNil(ProjectInstructions.readProjectBackup(projectId: projectId, stateDir: root))
    }

    func testCustomInstructionsDirsValuePreservesInheritedButStripsOtherSessions() {
        let stateDir = URL(fileURLWithPath: "/state", isDirectory: true)
        let sessionsRoot = ProjectInstructions.sessionsRoot(stateDir: stateDir)
        let mine = ProjectInstructions.sessionRoot(sessionId: "mine", stateDir: stateDir)
        let other = ProjectInstructions.sessionRoot(sessionId: "other", stateDir: stateDir)

        // Session dir placed first; user/global inherited dirs preserved and de-duped.
        XCTAssertEqual(
            ProjectInstructions.customInstructionsDirsValue(
                sessionRoot: mine, inherited: "/one, /two", managedSessionsRoot: sessionsRoot),
            "\(mine.path),/one,/two"
        )
        // Another session's app-managed root leaking in via the inherited env is
        // stripped, so its applyTo:"**" file can't apply here.
        XCTAssertEqual(
            ProjectInstructions.customInstructionsDirsValue(
                sessionRoot: mine, inherited: "\(other.path),/user/global",
                managedSessionsRoot: sessionsRoot),
            "\(mine.path),/user/global"
        )
        // My own root arriving via inherited isn't duplicated.
        XCTAssertEqual(
            ProjectInstructions.customInstructionsDirsValue(
                sessionRoot: mine, inherited: mine.path, managedSessionsRoot: sessionsRoot),
            mine.path
        )
        // No session dir → inherited (non-managed) passes through unchanged.
        XCTAssertEqual(
            ProjectInstructions.customInstructionsDirsValue(
                sessionRoot: nil, inherited: "/one", managedSessionsRoot: sessionsRoot),
            "/one"
        )
        // Nothing to set → nil.
        XCTAssertNil(
            ProjectInstructions.customInstructionsDirsValue(
                sessionRoot: nil, inherited: nil, managedSessionsRoot: sessionsRoot))
    }
}
