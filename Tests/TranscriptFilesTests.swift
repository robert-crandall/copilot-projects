import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

final class TranscriptFilesTests: XCTestCase {
    private let session = "copilot-session"

    private func turnJSON(_ id: String, endedAt: String? = "2026-07-12T00:00:01Z") -> String {
        """
        {"id":"\(id)","startedAt":"2026-07-12T00:00:00Z",\
        "endedAt":\(endedAt.map { "\"\($0)\"" } ?? "null"),"kind":"foreground",\
        "userContent":"\(id)","assistantMessages":[],"tools":[],"isAborted":false}
        """
    }

    private func sealed(
        schemaVersion: Int = 4,
        turns: [String] = ["stored"],
        revision: String? = "r2",
        previousRevision: String? = "r2",
        updatedAt: String = "2026-07-12T00:00:05Z"
    ) -> Data {
        var fields = [
            #""schemaVersion":\#(schemaVersion)"#,
            #""copilotSessionId":"\#(session)""#,
            #""ownerPid":1"#,
            #""turns":[\#(turns.map { turnJSON($0) }.joined(separator: ","))]"#,
            #""updatedAt":"\#(updatedAt)""#,
        ]
        if let revision { fields.append(#""revision":"\#(revision)""#) }
        if let previousRevision { fields.append(#""previousRevision":"\#(previousRevision)""#) }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    private func live(
        baseRevision: String = "r2",
        copilotSessionId: String? = nil,
        turnId: String = "pending",
        updatedAt: String = "2026-07-12T00:00:09Z"
    ) -> Data {
        Data("""
        {"schemaVersion":1,"copilotSessionId":"\(copilotSessionId ?? session)",\
        "baseRevision":"\(baseRevision)","updatedAt":"\(updatedAt)",\
        "turn":\(turnJSON(turnId, endedAt: nil))}
        """.utf8)
    }

    private func merge(_ sealed: Data, _ live: Data?) -> TranscriptSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return TranscriptFiles.snapshot(sealed: sealed, live: live, decoder: decoder)
    }

    func testLiveTurnExtendingTheSealedRevisionIsAppended() throws {
        let snapshot = try XCTUnwrap(merge(sealed(), live()))
        XCTAssertEqual(snapshot.schemaVersion, 3)
        XCTAssertEqual(snapshot.copilotSessionId, session)
        XCTAssertEqual(snapshot.turns.map(\.id), ["stored", "pending"])
        XCTAssertNil(snapshot.turns[1].endedAt)
        XCTAssertEqual(snapshot.updatedAt, ISO8601DateFormatter().date(from: "2026-07-12T00:00:09Z"))
    }

    func testLiveTurnExtendingTheNamedPreviousRevisionIsAppended() throws {
        let snapshot = try XCTUnwrap(merge(sealed(previousRevision: "r1"), live(baseRevision: "r1")))
        XCTAssertEqual(snapshot.turns.map(\.id), ["stored", "pending"])
    }

    func testUnrelatedForeignOrRepeatedLiveTurnsAreIgnored() throws {
        let cases: [(String, Data, Data?)] = [
            ("another revision", sealed(), live(baseRevision: "r0")),
            ("another conversation", sealed(), live(copilotSessionId: "other-session")),
            ("already sealed", sealed(turns: ["stored", "pending"]), live()),
            ("sealed without a revision", sealed(revision: nil, previousRevision: nil), live()),
            ("malformed", sealed(), Data("{\"schemaVersion\":1".utf8)),
            ("unknown live version", sealed(), Data(String(decoding: live(), as: UTF8.self)
                .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)),
            ("missing", sealed(), nil),
        ]
        for (name, sealedData, liveData) in cases {
            let snapshot = try XCTUnwrap(merge(sealedData, liveData), name)
            XCTAssertEqual(
                snapshot.turns.map(\.id),
                name == "already sealed" ? ["stored", "pending"] : ["stored"],
                name
            )
            XCTAssertEqual(
                snapshot.updatedAt,
                ISO8601DateFormatter().date(from: "2026-07-12T00:00:05Z"),
                name
            )
        }
    }

    /// A version 3 file predates the live file and carries its turn in progress
    /// inline, so a live file beside it is stale.
    func testLegacySnapshotIgnoresTheLiveFile() throws {
        let snapshot = try XCTUnwrap(merge(
            sealed(schemaVersion: 3, turns: ["stored", "inline"], revision: nil, previousRevision: nil),
            live(baseRevision: "r2")
        ))
        XCTAssertEqual(snapshot.schemaVersion, 3)
        XCTAssertEqual(snapshot.turns.map(\.id), ["stored", "inline"])
    }

    func testUnknownSealedVersionIsUnreadable() {
        XCTAssertNil(merge(sealed(schemaVersion: 5), live()))
        XCTAssertNil(merge(sealed(schemaVersion: 2), nil))
    }

    func testMergedSnapshotsNeverCarryTheFileRevisions() throws {
        let snapshot = try XCTUnwrap(merge(sealed(), live()))
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("revision"), encoded)
        XCTAssertFalse(encoded.contains("Revision"), encoded)
    }

    func testLastActivityIsTheLaterOfBothFiles() {
        let signature = { (seconds: TimeInterval) in
            FileSignature(attributes: [
                .size: NSNumber(value: 1), .systemFileNumber: NSNumber(value: 1),
                .modificationDate: Date(timeIntervalSinceReferenceDate: seconds),
            ])
        }
        let stamp = { (sealed: TimeInterval?, live: TimeInterval?) in
            SessionSearchIndex.Stamp(
                transcript: sealed.map(signature), owner: nil, quarantine: nil,
                live: live.map(signature)
            )
        }
        XCTAssertEqual(stamp(100, 200).lastActivity, Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(stamp(300, 200).lastActivity, Date(timeIntervalSinceReferenceDate: 300))
        XCTAssertEqual(stamp(100, nil).lastActivity, Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertNil(stamp(nil, 200).lastActivity)
    }

    @MainActor
    func testControllerFollowsALiveOnlyChange() async throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()
        let sealedURL = URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId))
        let liveURL = URL(fileURLWithPath: Paths.transcriptLivePath(sessionId: sessionId))
        try sealed().write(to: sealedURL, options: .atomic)
        try live(turnId: "first").write(to: liveURL, options: .atomic)

        let controller = TranscriptController(sessionId: sessionId)
        controller.start()
        for _ in 0 ..< 100 {
            if controller.snapshot?.turns.last?.id == "first" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.snapshot?.turns.map(\.id), ["stored", "first"])
        let revision = TranscriptController.remoteRevision(sessionId: sessionId)

        try live(turnId: "second").write(to: liveURL, options: .atomic)
        for _ in 0 ..< 100 {
            if controller.snapshot?.turns.last?.id == "second" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.snapshot?.turns.map(\.id), ["stored", "second"])
        XCTAssertNotEqual(TranscriptController.remoteRevision(sessionId: sessionId), revision)
        XCTAssertEqual(TranscriptController.loadRemoteSnapshot(sessionId: sessionId), controller.snapshot)

        try FileManager.default.removeItem(at: liveURL)
        for _ in 0 ..< 100 {
            if controller.snapshot?.turns.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.snapshot?.turns.map(\.id), ["stored"])
    }
}
