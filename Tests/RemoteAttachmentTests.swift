import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

final class RemoteAttachmentTests: XCTestCase {
    private func image() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testImmutableUploadSurvivesRestartAndIsBoundToConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAttachmentStore(sessionsDirectory: root)
        let id = UUID().uuidString.lowercased(), session = UUID().uuidString
        let bytes = try image()
        let now = Date()
        let metadata = try store.store(bytes, id: id, sessionId: session, conversationEpoch: "first", now: now)
        XCTAssertEqual(try store.store(bytes, id: id, sessionId: session, conversationEpoch: "first"), metadata)
        let reopened = RemoteAttachmentStore(sessionsDirectory: root)
        XCTAssertEqual(try reopened.image(id: id, sessionId: session, conversationEpoch: "first").1, bytes)
        XCTAssertThrowsError(try reopened.image(id: id, sessionId: session, conversationEpoch: "second"))
        XCTAssertThrowsError(try reopened.image(id: id, sessionId: UUID().uuidString, conversationEpoch: "first"))
        XCTAssertThrowsError(try reopened.image(id: "../anything", sessionId: session, conversationEpoch: "first"))
        XCTAssertThrowsError(try reopened.image(
            id: id, sessionId: session, conversationEpoch: "first",
            now: now.addingTimeInterval(RemoteAttachmentContract.lifetime + 1)
        ))
        let file = store.root.appendingPathComponent("\(id).image")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try Data("changed".utf8).write(to: file)
        XCTAssertThrowsError(try reopened.image(id: id, sessionId: session, conversationEpoch: "first"))
    }

    func testRejectsNonImagesOversizeAndSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAttachmentStore(sessionsDirectory: root)
        let session = UUID().uuidString
        for bytes in [Data("<svg/>".utf8), Data(repeating: 0, count: RemoteAttachmentContract.maxBytes + 1)] {
            XCTAssertThrowsError(try store.store(bytes, id: UUID().uuidString.lowercased(),
                                                 sessionId: session, conversationEpoch: "epoch"))
        }
        let id = UUID().uuidString.lowercased()
        _ = try store.store(image(), id: id, sessionId: session, conversationEpoch: "epoch")
        let file = store.root.appendingPathComponent("\(id).image")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("secret"))
        XCTAssertThrowsError(try store.image(id: id, sessionId: session, conversationEpoch: "epoch"))
    }

    func testAttachmentSchemaAndLimitsFailClosedWithoutBreakingText() {
        let id = UUID().uuidString.lowercased()
        XCTAssertTrue(RemoteSessionAction(kind: .send, prompt: "text", mode: .enqueue).isValid)
        XCTAssertTrue(RemoteSessionAction(kind: .send, prompt: "image", mode: .enqueue, attachmentIds: [id]).isValid)
        for ids in [[], ["../file"], [id, id], Array(repeating: id, count: 5)] {
            XCTAssertFalse(RemoteSessionAction(kind: .send, prompt: "image", mode: .enqueue, attachmentIds: ids).isValid)
        }
        XCTAssertFalse(RemoteSessionAction(kind: .abort, attachmentIds: [id]).isValid)
        let image = RemoteAttachment(id: id, sessionId: UUID().uuidString, conversationEpoch: "epoch",
            mimeType: "image/png", byteCount: 1000,
            expiresAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000) + 60000)
        XCTAssertTrue(RemoteImageCapabilities(maxImages: 1, maxBytes: 1000, mimeTypes: ["image/png"]).accepts([image]))
        XCTAssertFalse(RemoteImageCapabilities(maxImages: 1, maxBytes: 999, mimeTypes: ["image/png"]).accepts([image]))
        XCTAssertFalse(RemoteImageCapabilities(maxImages: 1, maxBytes: 1000, mimeTypes: ["image/jpeg"]).accepts([image]))
    }

    func testCorruptMetadataIsReclaimedAndModelRefusalDoesNotStoreBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAttachmentStore(sessionsDirectory: root)
        let session = UUID().uuidString, corruptID = UUID().uuidString.lowercased()
        let image = try image()
        _ = try store.store(image, id: corruptID, sessionId: session, conversationEpoch: "epoch")
        try Data("corrupt".utf8).write(to: store.root.appendingPathComponent("\(corruptID).json"))
        let goodID = UUID().uuidString.lowercased()
        _ = try store.store(image, id: goodID, sessionId: session, conversationEpoch: "epoch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(corruptID).image").path))
        XCTAssertEqual(try store.image(id: goodID, sessionId: session, conversationEpoch: "epoch").1, image)
        let refusedID = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try store.store(image, id: refusedID, sessionId: session, conversationEpoch: "epoch",
            limits: RemoteImageCapabilities(maxImages: 1, maxBytes: 1, mimeTypes: ["image/png"])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(refusedID).image").path))
    }

    func testDesktopNormalizationConvertsTIFFAndBuildsPreviewablePNGForJPEGAndWidePNG() async throws {
        let limits = RemoteImageCapabilities(
            maxImages: 4,
            maxBytes: RemoteAttachmentContract.maxBytes,
            mimeTypes: ["image/png", "image/jpeg"]
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 64, bitsPerPixel: 32
        ))
        let tiff = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
        let normalizedTIFF = try DesktopScreenshotAttachmentImage.normalized(tiff, limits: limits)
        XCTAssertEqual(normalizedTIFF.mimeType, "image/png")
        XCTAssertTrue(RemoteKittyPNGValidation.isStructurallyValid(normalizedTIFF.previewPNGData))

        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
        let normalizedJPEG = try DesktopScreenshotAttachmentImage.normalized(jpeg, limits: limits)
        XCTAssertEqual(normalizedJPEG.mimeType, "image/jpeg")
        XCTAssertEqual(normalizedJPEG.data, jpeg)
        let decodedJPEGPreview = try await TranscriptImageDecoder.shared.decode(
            normalizedJPEG.previewPNGData,
            maximumDimension: TranscriptImageDecoder.previewDimension
        )
        XCTAssertEqual(decodedJPEGPreview.width, 16)
        XCTAssertEqual(decodedJPEGPreview.height, 16)

        // A 5,120 x 64 PNG is valid for RemoteAttachmentStore (<= 16 MP) while exceeding
        // RemoteKittyPNGValidation's 4,096px terminal limit; previewPNGData scales to <= 2,048px.
        let wideBitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 5_120, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 5_120 * 4, bitsPerPixel: 32
        ))
        let widePNG = try XCTUnwrap(wideBitmap.representation(using: .png, properties: [:]))
        let normalizedWide = try DesktopScreenshotAttachmentImage.normalized(widePNG, limits: limits)
        XCTAssertEqual(normalizedWide.mimeType, "image/png")
        XCTAssertEqual(normalizedWide.data, widePNG)
        let decodedWidePreview = try await TranscriptImageDecoder.shared.decode(
            normalizedWide.previewPNGData,
            maximumDimension: TranscriptImageDecoder.previewDimension
        )
        XCTAssertLessThanOrEqual(decodedWidePreview.width, TranscriptImageDecoder.previewDimension)
    }

    @MainActor
    func testDesktopComposerGatesVisionCapabilitiesPasteboardAndFailClosedSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAttachmentStore(sessionsDirectory: root)
        let sessionId = UUID().uuidString
        let composer = DesktopSessionPromptComposer(sessionId: sessionId, attachmentStore: store)
        let now = Date()
        let limits = RemoteImageCapabilities(maxImages: 2, maxBytes: 500_000, mimeTypes: ["image/png", "image/jpeg"])
        let visionWorkflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: ["session-send", RemoteAttachmentContract.capability],
            sendReady: true,
            imageAttachments: limits
        )
        let textOnlyWorkflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: ["session-send"],
            sendReady: true,
            imageAttachments: nil
        )
        let epoch1 = AgentOperationProjection(conversationEpoch: "epoch-1", support: .receipts, receipts: [])

        XCTAssertNil(composer.imageLimits(workflow: textOnlyWorkflow, operation: epoch1, now: now))
        XCTAssertFalse(composer.canAttach(workflow: textOnlyWorkflow, operation: epoch1, now: now))
        XCTAssertEqual(composer.imageLimits(workflow: visionWorkflow, operation: epoch1, now: now), limits)
        XCTAssertTrue(composer.canAttach(workflow: visionWorkflow, operation: epoch1, now: now))

        // Paste TIFF image data via NSPasteboard into the composer.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32
        ))
        let tiffData = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(tiffData, forType: .tiff)

        let pasted = await composer.pasteFromPasteboard(pasteboard, workflow: visionWorkflow, operation: epoch1, now: now)
        XCTAssertTrue(pasted)
        XCTAssertEqual(composer.attachments.count, 1)
        let staged = try XCTUnwrap(composer.attachments.first)
        XCTAssertGreaterThan(staged.previewImageId, 0x00FF_FFFF, "Preview IDs stay outside Kitty's 24-bit namespace")
        XCTAssertEqual(try store.image(id: staged.id, sessionId: sessionId, conversationEpoch: "epoch-1", now: now).0, staged.attachment)

        // Image-only send without prompt text is blocked.
        XCTAssertFalse(composer.canSend(workflow: visionWorkflow, operation: epoch1, now: now))
        composer.prompt = "Analyze this screenshot"
        XCTAssertTrue(composer.canSend(workflow: visionWorkflow, operation: epoch1, now: now))

        // Switching to a non-vision model or new conversationEpoch blocks sending instead of dropping the image.
        XCTAssertFalse(composer.canSend(workflow: textOnlyWorkflow, operation: epoch1, now: now))
        XCTAssertNotNil(composer.attachmentsBlockedReason(workflow: textOnlyWorkflow, operation: epoch1, now: now))
        let epoch2 = AgentOperationProjection(conversationEpoch: "epoch-2", support: .receipts, receipts: [])
        XCTAssertFalse(composer.canSend(workflow: visionWorkflow, operation: epoch2, now: now))
        XCTAssertNotNil(composer.attachmentsBlockedReason(workflow: visionWorkflow, operation: epoch2, now: now))

        // Indeterminate send preserves draft and attachments until a receipt settles it.
        var dispatched: [RemoteSessionAction] = []
        await composer.send(
            workflow: visionWorkflow,
            operation: epoch1,
            onAction: { action in
                dispatched.append(action)
                return RemoteWorkflowActionResult(
                    state: .indeterminate,
                    message: "Outcome unknown.",
                    operationId: "op-1"
                )
            },
            now: now
        )
        XCTAssertEqual(dispatched.count, 1)
        XCTAssertEqual(dispatched.first?.attachmentIds, [staged.id])
        XCTAssertEqual(composer.pendingOperationId, "op-1")
        XCTAssertEqual(composer.attachments.count, 1)
        XCTAssertFalse(composer.canSend(workflow: visionWorkflow, operation: epoch1, now: now))

        composer.reconcileReceipts([
            RemoteOperationReceipt(
                operationId: "op-1",
                conversationEpoch: "epoch-1",
                kind: "session-send",
                state: .applied,
                updatedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
            )
        ], conversationEpoch: "epoch-1")
        XCTAssertNil(composer.pendingOperationId)
        XCTAssertEqual(composer.prompt, "")
        XCTAssertTrue(composer.attachments.isEmpty)
    }

    @MainActor
    func testAppModelRetainsComposerAcrossDrawerSwitchesAndCleansUpOnSessionClose() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let session = Session(title: "Composer session", cwd: root.path)
        let project = Project(name: "Composer project", cwd: root.path, sessions: [session], selectedSessionId: session.id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository,
            persistPermissionStatus: { _, _, _, _ in },
            isAppActive: { false },
            agentActivityDirectory: sessionsDir,
            resumeMarkerDirectory: sessionsDir,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        defer {
            model.forcePendingSessionDestroys()
            model.detachAllClients()
        }

        let now = Date()
        let limits = RemoteImageCapabilities(maxImages: 2, maxBytes: 500_000, mimeTypes: ["image/png"])
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: ["session-send", RemoteAttachmentContract.capability],
            sendReady: true,
            imageAttachments: limits
        )
        let operation = AgentOperationProjection(conversationEpoch: "epoch-1", support: .receipts, receipts: [])

        let composer = model.sessionPromptComposer(sessionId: session.id)
        composer.prompt = "Draft kept across drawer toggle"
        await composer.attachImageData([try image()], workflow: workflow, operation: operation, now: now)
        let stagedId = try XCTUnwrap(composer.attachments.first?.id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: model.attachmentStore.root.appendingPathComponent("\(stagedId).image").path
        ))
        XCTAssertTrue(model.sessionPromptComposer(sessionId: session.id) === composer)

        model.closeSession(projectId: project.id, sessionId: session.id)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: model.attachmentStore.root.appendingPathComponent("\(stagedId).image").path
        ))
    }
}
