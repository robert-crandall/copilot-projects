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

    func testProjectInstructionsSyncWritesAndRemoves() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectId = UUID().uuidString
        let file = ProjectInstructions.instructionsFile(projectId: projectId, stateDir: root)
        let expectedRoot = ProjectInstructions.rootDirectory(projectId: projectId, stateDir: root)

        // Non-empty → writes the file and always returns the (advertised) root dir.
        let dir = ProjectInstructions.sync(
            projectId: projectId, instructions: "Prefer tabs.", stateDir: root)
        XCTAssertEqual(dir, expectedRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("Prefer tabs."))

        // Empty → removes the file but still returns the root (it stays advertised so
        // instructions saved into an already-open session are picked up next launch).
        let cleared = ProjectInstructions.sync(
            projectId: projectId, instructions: "   ", stateDir: root)
        XCTAssertEqual(cleared, expectedRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testProjectInstructionsReadBackRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectId = UUID().uuidString
        // Missing file → nil.
        XCTAssertNil(ProjectInstructions.readInstructions(projectId: projectId, stateDir: root))

        // A body that itself contains a "---" line still round-trips (only the leading
        // frontmatter block is stripped).
        let original = "Line one.\n---\nLine two."
        ProjectInstructions.sync(projectId: projectId, instructions: original, stateDir: root)
        XCTAssertEqual(
            ProjectInstructions.readInstructions(projectId: projectId, stateDir: root),
            original
        )

        // Cleared → nil again.
        ProjectInstructions.sync(projectId: projectId, instructions: "", stateDir: root)
        XCTAssertNil(ProjectInstructions.readInstructions(projectId: projectId, stateDir: root))
    }

    func testCustomInstructionsDirsValuePreservesInherited() {
        let root = URL(fileURLWithPath: "/state/projects/abc", isDirectory: true)
        // Project dir is placed first, inherited values kept and de-duplicated.
        XCTAssertEqual(
            ProjectInstructions.customInstructionsDirsValue(
                projectRoot: root, inherited: "/one, /two"),
            "/state/projects/abc,/one,/two"
        )
        // No project dir → inherited passes through unchanged.
        XCTAssertEqual(
            ProjectInstructions.customInstructionsDirsValue(projectRoot: nil, inherited: "/one"),
            "/one"
        )
        // Already-present project dir isn't duplicated.
        XCTAssertEqual(
            ProjectInstructions.customInstructionsDirsValue(
                projectRoot: root, inherited: "/state/projects/abc"),
            "/state/projects/abc"
        )
        // Nothing to set → nil, so the caller leaves the environment untouched.
        XCTAssertNil(
            ProjectInstructions.customInstructionsDirsValue(projectRoot: nil, inherited: nil))
        XCTAssertNil(
            ProjectInstructions.customInstructionsDirsValue(projectRoot: nil, inherited: "  ,  "))
    }
}
