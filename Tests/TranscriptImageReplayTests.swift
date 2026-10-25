import Foundation
import XCTest
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

@MainActor
final class TranscriptImageReplayTests: XCTestCase {
    private final class Clock {
        var value = Date(timeIntervalSince1970: 100)
    }

    private func capture(_ clock: Clock) -> RemoteKittyImageCapture {
        RemoteKittyImageCapture(epoch: 0, budget: RemoteKittyImageCaptureBudget(), now: { clock.value })
    }

    private func transmit(_ capture: RemoteKittyImageCapture, png: Data, action: String = "T") {
        capture.ingest(remoteKittyFrameBytes(
            control: "a=\(action),f=100,t=d,U=1,i=42", base64Payload: png.base64EncodedString()
        )[...])
    }

    private func turn(_ id: String, start: TimeInterval) -> TranscriptTurn {
        TranscriptTurn(
            id: id, startedAt: Date(timeIntervalSince1970: start), endedAt: nil,
            kind: "foreground", userContent: id, assistantMessages: [], tools: [], isAborted: false
        )
    }

    private func snapshot(_ turns: [TranscriptTurn], totalTurns: Int? = nil) -> TranscriptSnapshot {
        TranscriptSnapshot(
            schemaVersion: 3, updatedAt: Date(timeIntervalSince1970: 300),
            copilotSessionId: "fixture", turns: turns, totalTurns: totalTurns
        )
    }

    func testIdenticalRedrawKeepsOriginalTurnWithNewestFetchVersion() throws {
        let clock = Clock(), capture = capture(clock)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        transmit(capture, png: png)
        let initial = TranscriptImageAssociation.attach(
            images: capture.retainedImageMetadata(), to: snapshot([turn("original", start: 90)])
        )
        XCTAssertEqual(initial.turns[0].images?.first?.contentVersion, 1)
        clock.value = Date(timeIntervalSince1970: 250)
        transmit(capture, png: png)
        let result = TranscriptImageAssociation.attach(images: capture.retainedImageMetadata(),
            to: snapshot([turn("original", start: 90), turn("later", start: 200)]))
        let image = try XCTUnwrap(result.turns[0].images?.first)
        XCTAssertEqual(image.contentVersion, 2)
        XCTAssertEqual(capture.imageData(imageId: image.imageId, version: image.contentVersion), png)
        XCTAssertNil(result.turns[1].images)
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, Date(timeIntervalSince1970: 100))
    }

    func testChangedBytesGetNewTurnInsteadOfBorrowingOldOrigin() {
        let clock = Clock(), capture = capture(clock)
        transmit(capture, png: remoteKittyTestPNGBytes(width: 2, height: 2))
        clock.value = Date(timeIntervalSince1970: 250)
        transmit(capture, png: remoteKittyTestPNGBytes(width: 3, height: 3))
        let result = TranscriptImageAssociation.attach(images: capture.retainedImageMetadata(),
            to: snapshot([turn("original", start: 90), turn("later", start: 200)]))
        XCTAssertNil(result.turns[0].images)
        XCTAssertEqual(result.turns[1].images?.first?.contentVersion, 2)
    }

    func testPlacementResizeKeepsOriginWhileDataDeletionStartsFresh() {
        let clock = Clock(), capture = capture(clock)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        transmit(capture, png: png)
        clock.value = Date(timeIntervalSince1970: 250)
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=42")[...])
        XCTAssertTrue(capture.retainedImageMetadata().isEmpty)
        capture.ingest(remoteKittyFrameBytes(control: "a=p,U=1,i=42,c=4,r=3")[...])
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, Date(timeIntervalSince1970: 100))
        transmit(capture, png: png)
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, Date(timeIntervalSince1970: 100))
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=I,i=42")[...])
        transmit(capture, png: png)
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, clock.value)
    }

    func testUndisplayedPreloadDoesNotBorrowEarlierTurn() {
        let clock = Clock(), capture = capture(clock)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        transmit(capture, png: png, action: "t")
        XCTAssertTrue(capture.retainedImageMetadata().isEmpty)
        clock.value = Date(timeIntervalSince1970: 250)
        transmit(capture, png: png)
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, clock.value)
    }

    func testRedrawDoesNotMoveImageIntoNewerTranscriptWindow() {
        let clock = Clock(), capture = capture(clock)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        transmit(capture, png: png)
        clock.value = Date(timeIntervalSince1970: 250)
        transmit(capture, png: png)
        let result = TranscriptImageAssociation.attach(images: capture.retainedImageMetadata(),
            to: snapshot([turn("later", start: 200)], totalTurns: 2))
        XCTAssertNil(result.turns[0].images, "The image belongs to a turn outside this window")
        XCTAssertEqual(result.totalTurns, 2)
    }

    func testRestoreWithoutOriginDoesNotInventHistoricalAssociation() {
        let clock = Clock(), capture = capture(clock)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let restoredVersion = UInt64(1) << 32
        capture.beginRestoring()
        XCTAssertTrue(capture.restoreEntry(imageId: 42, version: restoredVersion, data: png))
        XCTAssertTrue(capture.restoreCurrentSelection(imageId: 42, version: restoredVersion, placementId: nil))
        capture.finishRestoring()
        XCTAssertTrue(capture.retainedImageMetadata().isEmpty)
        capture.ingest(remoteKittyFrameBytes(control: "a=p,U=1,i=42,c=4,r=3")[...])
        XCTAssertTrue(capture.retainedImageMetadata().isEmpty)
        clock.value = Date(timeIntervalSince1970: 250)
        transmit(capture, png: png)
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, clock.value)
    }

    func testDiskStorePersistsAndRestoresDisplayedAtAndPixelDimensions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteKittyImageDiskStore(root: root)
        let clock = Clock()
        clock.value = Date(timeIntervalSince1970: 123)
        let writer = RemoteKittyImageCapture(
            sessionId: "s1",
            epoch: 0,
            budget: RemoteKittyImageCaptureBudget(),
            diskStore: store,
            now: { clock.value }
        )
        let png = remoteKittyTestPNGBytes(width: 5, height: 3)
        transmit(writer, png: png)
        await store.barrierForTesting()

        let restored = await store.restore(sessionId: "s1")
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertEqual(restored.entries.first?.displayedAt, Date(timeIntervalSince1970: 123))

        clock.value = Date(timeIntervalSince1970: 400)
        let reader = RemoteKittyImageCapture(
            sessionId: "s1",
            epoch: 1,
            budget: RemoteKittyImageCaptureBudget(),
            diskStore: store,
            now: { clock.value }
        )
        reader.beginRestoring()
        for entry in restored.entries {
            XCTAssertTrue(reader.restoreEntry(
                imageId: entry.imageId,
                version: entry.version,
                data: entry.data,
                displayedAt: entry.displayedAt,
                awaitingFirstDisplay: entry.awaitingFirstDisplay
            ))
        }
        XCTAssertTrue(reader.restoreCurrentSelection(imageId: 42, version: restored.entries[0].version, placementId: nil))
        reader.finishRestoring()

        let meta = try XCTUnwrap(reader.retainedImageMetadata().first)
        XCTAssertEqual(meta.displayedAt, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(meta.pixelWidth, 5)
        XCTAssertEqual(meta.pixelHeight, 3)

        // Preload (`a=t`) followed by restart and then first placement (`a=p`)
        // preserves awaitingFirstDisplay across the restart and stamps displayedAt on placement.
        clock.value = Date(timeIntervalSince1970: 500)
        reader.ingest(remoteKittyFrameBytes(
            control: "a=t,f=100,t=d,U=1,i=77",
            base64Payload: png.base64EncodedString()
        )[...])
        await store.barrierForTesting()

        let restoredPreload = await store.restore(sessionId: "s1")
        let preloadEntry = try XCTUnwrap(restoredPreload.entries.first { $0.imageId == 77 })
        XCTAssertNil(preloadEntry.displayedAt)
        XCTAssertTrue(preloadEntry.awaitingFirstDisplay)

        clock.value = Date(timeIntervalSince1970: 525)
        let postRestartReader = RemoteKittyImageCapture(
            sessionId: "s1",
            epoch: 2,
            budget: RemoteKittyImageCaptureBudget(),
            diskStore: store,
            now: { clock.value }
        )
        postRestartReader.beginRestoring()
        for entry in restoredPreload.entries {
            XCTAssertTrue(postRestartReader.restoreEntry(
                imageId: entry.imageId,
                version: entry.version,
                data: entry.data,
                displayedAt: entry.displayedAt,
                awaitingFirstDisplay: entry.awaitingFirstDisplay
            ))
        }
        postRestartReader.finishRestoring()
        XCTAssertFalse(postRestartReader.retainedImageMetadata().contains { $0.imageId == 77 })

        clock.value = Date(timeIntervalSince1970: 555)
        postRestartReader.ingest(remoteKittyFrameBytes(control: "a=p,U=1,i=77,c=4,r=3")[...])
        let placedMeta = try XCTUnwrap(postRestartReader.retainedImageMetadata().first { $0.imageId == 77 })
        XCTAssertEqual(placedMeta.displayedAt, Date(timeIntervalSince1970: 555))
        await store.barrierForTesting()

        let restoredAfterPlacement = await store.restore(sessionId: "s1")
        let placedEntry = try XCTUnwrap(restoredAfterPlacement.entries.first { $0.imageId == 77 })
        XCTAssertEqual(placedEntry.displayedAt, Date(timeIntervalSince1970: 555))
        XCTAssertFalse(placedEntry.awaitingFirstDisplay)
    }

    func testResumeAndPostTurnReplayDoNotAttachToEndedOrResumeTurns() {
        let turns = [
            TranscriptTurn(
                id: "t1",
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 150),
                kind: "foreground",
                userContent: "first",
                assistantMessages: [],
                tools: [],
                isAborted: false
            ),
            TranscriptTurn(
                id: "session-resume-abc",
                startedAt: Date(timeIntervalSince1970: 151),
                endedAt: Date(timeIntervalSince1970: 151),
                kind: "automated",
                userContent: "",
                assistantMessages: [],
                tools: [],
                isAborted: false
            ),
        ]
        let replayedDuringResume = RemoteKittyImageCapture.RetainedImageInfo(
            imageId: 1,
            version: 1,
            displayedAt: Date(timeIntervalSince1970: 151.5)
        )
        let replayedWhileIdle = RemoteKittyImageCapture.RetainedImageInfo(
            imageId: 2,
            version: 1,
            displayedAt: Date(timeIntervalSince1970: 200)
        )
        let result = TranscriptImageAssociation.attach(
            images: [replayedDuringResume, replayedWhileIdle],
            to: snapshot(turns)
        )
        XCTAssertNil(result.turns[0].images)
        XCTAssertNil(result.turns[1].images)
    }

    func testTimelineItemsInterleaveChronologicallyAcrossWireEncoding() throws {
        let baseTurn = TranscriptTurn(
            id: "t1",
            startedAt: Date(timeIntervalSince1970: 100.1),
            endedAt: Date(timeIntervalSince1970: 140),
            kind: "foreground",
            userContent: "check screenshots",
            assistantMessages: [
                TranscriptAssistantMessage(
                    id: "m1",
                    timestamp: Date(timeIntervalSince1970: 100.8),
                    content: "Starting preview"
                ),
                TranscriptAssistantMessage(
                    id: "m2",
                    timestamp: Date(timeIntervalSince1970: 120.2),
                    content: "Captured first view"
                ),
                TranscriptAssistantMessage(
                    id: "m3",
                    timestamp: Date(timeIntervalSince1970: 120.9),
                    content: "All done"
                ),
            ],
            tools: [],
            isAborted: false
        )
        let images = [
            // User prompt attachment rendered before m1 within the same whole second (100.3 < 100.8)
            RemoteKittyImageCapture.RetainedImageInfo(
                imageId: 1,
                version: 10,
                displayedAt: Date(timeIntervalSince1970: 100.3),
                pixelWidth: 800,
                pixelHeight: 600
            ),
            // Tool image rendered between m2 (120.2) and m3 (120.9) within the same whole second
            RemoteKittyImageCapture.RetainedImageInfo(
                imageId: 2,
                version: 20,
                displayedAt: Date(timeIntervalSince1970: 120.5),
                pixelWidth: 1200,
                pixelHeight: 900
            ),
        ]
        let attachedInMemory = TranscriptImageAssociation.attach(
            images: images,
            to: snapshot([baseTurn])
        )
        XCTAssertEqual(
            attachedInMemory.turns[0].timelineItems().map(\.id),
            ["image-1", "assistant-m1", "assistant-m2", "image-2", "assistant-m3"]
        )
        let data = try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot([baseTurn]),
            images: images,
            limit: nil
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TranscriptSnapshot.self, from: data)
        let items = decoded.turns[0].timelineItems()
        XCTAssertEqual(
            items.map(\.id),
            ["image-1", "assistant-m1", "assistant-m2", "image-2", "assistant-m3"]
        )
        let legacyTurn = TranscriptTurn(
            id: "legacy",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 140),
            kind: "foreground",
            userContent: "legacy",
            assistantMessages: baseTurn.assistantMessages,
            tools: [],
            isAborted: false,
            images: [TranscriptImageRef(imageId: 99, contentVersion: 1)]
        )
        XCTAssertEqual(
            legacyTurn.timelineItems().map(\.id),
            ["assistant-m1", "assistant-m2", "assistant-m3", "image-99"]
        )
    }
}
