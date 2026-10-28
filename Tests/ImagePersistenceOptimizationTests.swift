import Foundation
import XCTest
@testable import CopilotProjectsHost

final class ImagePersistenceOptimizationTests: XCTestCase {
    @MainActor
    func testMultiImagePlacementClearPersistsManifestOnce() async {
        let root = imagePersistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "batch-clear"
        let store = RemoteKittyImageDiskStore(root: root)
        let capture = imagePersistenceCapture(sessionId: sessionId, store: store)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=1,c=2,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=2,c=3,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        await store.flush()
        let before = await store.manifestPersistCountForTesting()

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=a")[...])
        let after = await store.manifestPersistCountForTesting()

        XCTAssertEqual(after - before, 1)
        XCTAssertEqual(capture.imageData(imageId: 1, version: 1), png)
        XCTAssertEqual(capture.imageData(imageId: 2, version: 2), png)

        let reopened = RemoteKittyImageDiskStore(root: root)
        let restored = await reopened.restore(sessionId: sessionId)
        XCTAssertEqual(Set(restored.entries.map(\.imageId)), [1, 2])
        XCTAssertTrue(restored.currentSelections.isEmpty)
    }

    @MainActor
    func testSelectivePlacementDeletionPreservesSiblingAndOtherImageSelections() async {
        let root = imagePersistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "selective-clear"
        let store = RemoteKittyImageDiskStore(root: root)
        let capture = imagePersistenceCapture(sessionId: sessionId, store: store)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=10,p=1,c=2,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=p,U=1,i=10,p=2,c=2,r=1"
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=20,c=2,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        await store.flush()

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=10,p=1")[...])
        await store.flush()

        let reopened = RemoteKittyImageDiskStore(root: root)
        let restored = await reopened.restore(sessionId: sessionId)
        XCTAssertEqual(Set(restored.entries.map(\.imageId)), [10, 20])
        XCTAssertEqual(restored.currentSelections.count, 2)
        XCTAssertTrue(restored.currentSelections.contains {
            $0.imageId == 10 && $0.placementId == 2
        })
        XCTAssertTrue(restored.currentSelections.contains {
            $0.imageId == 20 && $0.placementId == nil
        })
        XCTAssertFalse(restored.currentSelections.contains {
            $0.imageId == 10 && $0.placementId == 1
        })
    }

    @MainActor
    func testBatchClearRemainsFIFOWithLaterRetain() async {
        let root = imagePersistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "ordered-clear"
        let store = RemoteKittyImageDiskStore(root: root)
        let capture = imagePersistenceCapture(sessionId: sessionId, store: store)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        for imageId: UInt32 in 1 ... 2 {
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(imageId),c=1,r=1",
                base64Payload: png.base64EncodedString()
            )[...])
        }
        await store.flush()

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=a")[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=3,c=1,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        await store.flush()

        let reopened = RemoteKittyImageDiskStore(root: root)
        let restored = await reopened.restore(sessionId: sessionId)
        XCTAssertEqual(Set(restored.entries.map(\.imageId)), [1, 2, 3])
        XCTAssertEqual(restored.currentSelections.map(\.imageId), [3])
    }

    @MainActor
    func testBatchClearPersistenceFailureFailClosesQueuedLaterRetain() async throws {
        let root = imagePersistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "failed-clear"
        let store = RemoteKittyImageDiskStore(root: root)
        let capture = imagePersistenceCapture(sessionId: sessionId, store: store)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        for imageId: UInt32 in 1 ... 2 {
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(imageId),c=1,r=1",
                base64Payload: png.base64EncodedString()
            )[...])
        }
        await store.flush()

        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=a")[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=3,c=1,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        await store.flush()

        XCTAssertTrue(store.isPersistenceDisabledForTesting(sessionId: sessionId))
        XCTAssertTrue(store.isTombstonedForTesting(sessionId: sessionId))
        let entryCount = await store.totalEntryCountForTesting()
        let reopened = RemoteKittyImageDiskStore(root: root)
        let restored = await reopened.restore(sessionId: sessionId)
        XCTAssertEqual(entryCount, 0)
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertTrue(restored.currentSelections.isEmpty)
    }

    @MainActor
    func testStartupReconciliationSkipsFullByteReadsForSignatureMatchedEntriesAndEvictsModifiedOrSymlinkedFiles() async throws {
        let root = imagePersistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "startup-signature"
        let png1 = remoteKittyTestPNGBytes(width: 2, height: 2)
        let png2 = remoteKittyTestPNGBytes(width: 3, height: 3)
        let png3 = remoteKittyTestPNGBytes(width: 4, height: 4)

        let writer = RemoteKittyImageDiskStore(root: root)
        writer.persistRetain(
            sessionId: sessionId,
            imageId: 1,
            version: 1,
            data: png1,
            currentSelections: [RemoteKittyPersistedPlacementSelection(
                version: 1, placementId: nil, rows: 1, columns: 2, x: nil, y: nil, z: nil
            )]
        )
        writer.persistRetain(
            sessionId: sessionId,
            imageId: 2,
            version: 1,
            data: png2,
            currentSelections: [RemoteKittyPersistedPlacementSelection(
                version: 1, placementId: nil, rows: 1, columns: 3, x: nil, y: nil, z: nil
            )]
        )
        writer.persistRetain(
            sessionId: sessionId,
            imageId: 3,
            version: 1,
            data: png3,
            currentSelections: [RemoteKittyPersistedPlacementSelection(
                version: 1, placementId: nil, rows: 1, columns: 4, x: nil, y: nil, z: nil
            )]
        )
        await writer.flush()

        // Reload 1: all entries match their recorded file signatures, so startup
        // cleanup validates via stat without reading any PNG payloads or rewriting manifest.json.
        let cleanReload = RemoteKittyImageDiskStore(root: root)
        cleanReload.activate()
        await cleanReload.flush()
        let cleanReads = await cleanReload.fullValidationReadCountForTesting()
        let cleanPersists = await cleanReload.manifestPersistCountForTesting()
        let cleanCount = await cleanReload.totalEntryCountForTesting()
        XCTAssertEqual(cleanReads, 0)
        XCTAssertEqual(cleanPersists, 0)
        XCTAssertEqual(cleanCount, 3)

        // Overwrite image 2 in place with same-byte-count non-PNG bytes (size still matches,
        // signature mismatches -> full validation runs and evicts image 2).
        let image2URL = cleanReload.dataFileURLForTesting(sessionId: sessionId, imageId: 2, version: 1)
        try Data(repeating: 0x5A, count: png2.count).write(to: image2URL)

        // Replace image 3 with a symlink to a valid PNG outside dataDir (rejected by lstat regular-file check).
        let image3URL = cleanReload.dataFileURLForTesting(sessionId: sessionId, imageId: 3, version: 1)
        let externalTargetURL = root.appendingPathComponent("external-target.png", isDirectory: false)
        try FileManager.default.moveItem(at: image3URL, to: externalTargetURL)
        try FileManager.default.createSymbolicLink(at: image3URL, withDestinationURL: externalTargetURL)

        let tamperedReload = RemoteKittyImageDiskStore(root: root)
        tamperedReload.activate()
        await tamperedReload.flush()
        let tamperedReads = await tamperedReload.fullValidationReadCountForTesting()
        let image1Exists = await tamperedReload.entryExistsForTesting(sessionId: sessionId, imageId: 1, version: 1)
        let image2Exists = await tamperedReload.entryExistsForTesting(sessionId: sessionId, imageId: 2, version: 1)
        let image3Exists = await tamperedReload.entryExistsForTesting(sessionId: sessionId, imageId: 3, version: 1)
        XCTAssertEqual(tamperedReads, 1, "only the same-size modified regular file should trigger a full byte read; untouched image 1 and rejected symlink image 3 should not")
        XCTAssertTrue(image1Exists)
        XCTAssertFalse(image2Exists)
        XCTAssertFalse(image3Exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image2URL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: image3URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalTargetURL.path))

        let restored = await tamperedReload.restore(sessionId: sessionId)
        XCTAssertEqual(restored.entries.map(\.imageId), [1])
        XCTAssertEqual(restored.entries.first?.data, png1)
        XCTAssertEqual(restored.currentSelections.map(\.imageId), [1])
    }

    @MainActor
    func testLegacyManifestWithoutSignatureBackfillsOnStartupAndSkipsFullReadOnNextLaunch() async throws {
        let root = imagePersistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "legacy-signature"
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let pathStore = RemoteKittyImageDiskStore(root: root)
        let dataURL = pathStore.dataFileURLForTesting(sessionId: sessionId, imageId: 1, version: 1)
        try FileManager.default.createDirectory(
            at: dataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: dataURL)
        let legacyManifest = """
        {
          "schemaVersion": 1,
          "entries": [{
            "sessionId": "\(sessionId)",
            "imageId": 1,
            "version": 1,
            "byteCount": \(png.count)
          }],
          "selections": []
        }
        """
        try Data(legacyManifest.utf8).write(to: root.appendingPathComponent("manifest.json", isDirectory: false))

        let firstLaunch = RemoteKittyImageDiskStore(root: root)
        firstLaunch.activate()
        await firstLaunch.flush()
        let firstReads = await firstLaunch.fullValidationReadCountForTesting()
        let firstPersists = await firstLaunch.manifestPersistCountForTesting()
        let firstExists = await firstLaunch.entryExistsForTesting(sessionId: sessionId, imageId: 1, version: 1)
        XCTAssertEqual(firstReads, 1)
        XCTAssertEqual(firstPersists, 1)
        XCTAssertTrue(firstExists)

        let secondLaunch = RemoteKittyImageDiskStore(root: root)
        secondLaunch.activate()
        await secondLaunch.flush()
        let secondReads = await secondLaunch.fullValidationReadCountForTesting()
        let secondPersists = await secondLaunch.manifestPersistCountForTesting()
        let secondExists = await secondLaunch.entryExistsForTesting(sessionId: sessionId, imageId: 1, version: 1)
        XCTAssertEqual(secondReads, 0)
        XCTAssertEqual(secondPersists, 0)
        XCTAssertTrue(secondExists)
    }
}

@MainActor
private func imagePersistenceCapture(
    sessionId: String,
    store: RemoteKittyImageDiskStore
) -> RemoteKittyImageCapture {
    RemoteKittyImageCapture(
        sessionId: sessionId,
        epoch: 0,
        budget: RemoteKittyImageCaptureBudget(),
        diskStore: store
    )
}

private func imagePersistenceTestRoot() -> URL {
    URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("image-persistence-\(UUID().uuidString)", isDirectory: true)
}
