import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import CopilotProjectsCore
import CopilotProjectsProtocol

enum DesktopScreenshotAttachmentImage {
    struct NormalizedAttachment: Sendable, Equatable {
        let data: Data
        let mimeType: String
        let previewPNGData: Data
    }

    enum PasteboardSource {
        case fileURLs([URL])
        case imagePayloads([Data])
    }

    enum AttachmentError: LocalizedError, Equatable {
        case invalid
        case tooLarge
        case emptyPasteboard
        case tooManyImages(Int)

        var errorDescription: String? {
            switch self {
            case .invalid:
                "Choose a valid screenshot up to 16 megapixels and 20 MB."
            case .tooLarge:
                "This screenshot cannot fit the selected model's image limit. Crop it and try again."
            case .emptyPasteboard:
                "Clipboard does not contain an image."
            case .tooManyImages(let limit):
                "This model allows up to \(limit) screenshot(s) per message."
            }
        }
    }

    static let maxSourceBytes = 20 * 1_024 * 1_024

    static func normalized(
        _ data: Data,
        limits: RemoteImageCapabilities
    ) throws -> NormalizedAttachment {
        guard limits.isValid,
              !data.isEmpty,
              data.count <= maxSourceBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) >= 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= 16_384, height <= 16_384,
              width <= RemoteAttachmentContract.maxPixels / height,
              let previewCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: TranscriptImageDecoder.previewDimension,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let previewPNGData = NSBitmapImageRep(cgImage: previewCGImage)
                  .representation(using: .png, properties: [:]) else {
            throw AttachmentError.invalid
        }

        if let sourceType = CGImageSourceGetType(source) as String?,
           let directMime = sourceType == "public.png" ? "image/png"
               : (sourceType == "public.jpeg" ? "image/jpeg" : nil),
           limits.mimeTypes.contains(directMime),
           data.count <= limits.maxBytes {
            return NormalizedAttachment(
                data: data,
                mimeType: directMime,
                previewPNGData: previewPNGData
            )
        }

        guard let normalizedCGImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else {
            throw AttachmentError.invalid
        }
        let bitmap = NSBitmapImageRep(cgImage: normalizedCGImage)
        if limits.mimeTypes.contains("image/png"),
           let png = bitmap.representation(using: .png, properties: [:]),
           png.count <= limits.maxBytes {
            return NormalizedAttachment(
                data: png,
                mimeType: "image/png",
                previewPNGData: previewPNGData
            )
        }
        if limits.mimeTypes.contains("image/jpeg") {
            for factor in [0.9, 0.75, 0.6] {
                if let jpeg = bitmap.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: factor]
                ), jpeg.count <= limits.maxBytes {
                    return NormalizedAttachment(
                        data: jpeg,
                        mimeType: "image/jpeg",
                        previewPNGData: previewPNGData
                    )
                }
            }
        }
        throw AttachmentError.tooLarge
    }

    static func hasPasteboardImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], urls.contains(where: isSupportedImageFileURL) {
            return true
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            .tiff,
        ]
        return (pasteboard.pasteboardItems ?? []).contains { item in
            imageTypes.contains { item.types.contains($0) }
        }
    }

    static func pasteboardSources(
        from pasteboard: NSPasteboard = .general,
        remainingCapacity: Int,
        maxImages: Int
    ) throws -> PasteboardSource {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            let imageURLs = urls.filter(isSupportedImageFileURL)
            if !imageURLs.isEmpty {
                guard imageURLs.count <= remainingCapacity else {
                    throw AttachmentError.tooManyImages(maxImages)
                }
                return .fileURLs(imageURLs)
            }
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            .tiff,
        ]
        let items = (pasteboard.pasteboardItems ?? []).filter { item in
            imageTypes.contains { item.types.contains($0) }
        }
        guard !items.isEmpty else {
            throw AttachmentError.emptyPasteboard
        }
        guard items.count <= remainingCapacity else {
            throw AttachmentError.tooManyImages(maxImages)
        }
        var payloads: [Data] = []
        for item in items {
            guard let matchedType = imageTypes.first(where: { item.types.contains($0) }),
                  let data = item.data(forType: matchedType),
                  !data.isEmpty,
                  data.count <= maxSourceBytes else {
                throw AttachmentError.invalid
            }
            payloads.append(data)
        }
        return .imagePayloads(payloads)
    }

    static func readImageFileData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0, size <= maxSourceBytes else {
            throw AttachmentError.invalid
        }
        if let contentType = values.contentType, !contentType.conforms(to: .image) {
            throw AttachmentError.invalid
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= maxSourceBytes else {
            throw AttachmentError.invalid
        }
        return data
    }

    private static func isSupportedImageFileURL(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }
}

@MainActor
final class DesktopSessionPromptComposer: ObservableObject {
    struct StagedAttachment: Identifiable, Equatable, Sendable {
        let id: String
        let attachment: RemoteAttachment
        let data: Data
        let previewPNGData: Data
        let previewImageId: UInt32
        let previewVersion: UInt64
    }

    let sessionId: String
    let attachmentStore: RemoteAttachmentStore
    @Published var prompt: String = ""
    @Published var mode: RemotePromptMode = .immediate
    @Published var isPromptFieldFocused = false
    @Published private(set) var attachments: [StagedAttachment] = []
    @Published private(set) var attachedEpoch: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSending = false
    @Published private(set) var isAttaching = false
    @Published private(set) var pendingOperationId: String?
    private var pendingOperationEpoch: String?
    private var previewSequence: UInt32 = 0
    private var attachGeneration: UInt64 = 0

    init(
        sessionId: String,
        attachmentStore: RemoteAttachmentStore = RemoteAttachmentStore()
    ) {
        self.sessionId = sessionId
        self.attachmentStore = attachmentStore
    }

    func imageLimits(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> RemoteImageCapabilities? {
        guard operation.support == .receipts,
              let epoch = operation.conversationEpoch,
              RemoteAttachmentContract.validScope(sessionId: sessionId, conversationEpoch: epoch),
              let workflow,
              workflow.supports(.send, at: now),
              workflow.capabilities.contains(RemoteAttachmentContract.capability),
              let limits = workflow.imageAttachments,
              limits.isValid else {
            return nil
        }
        return limits
    }

    func canAttach(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> Bool {
        guard !isSending, !isAttaching, pendingOperationId == nil,
              let limits = imageLimits(workflow: workflow, operation: operation, now: now),
              let epoch = operation.conversationEpoch else {
            return false
        }
        guard attachments.count < limits.maxImages else { return false }
        return attachments.isEmpty || attachedEpoch == epoch
    }

    func attachHelpText(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> String {
        if let limits = imageLimits(workflow: workflow, operation: operation, now: now) {
            return "Attach PNG or JPEG screenshots (up to \(limits.maxImages) images, \(limits.maxBytes / 1_024) KB each)."
        }
        return "Requires an active Copilot session and a vision-capable model."
    }

    func attachmentsBlockedReason(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> String? {
        guard !attachments.isEmpty else { return nil }
        guard operation.support == .receipts,
              let currentEpoch = operation.conversationEpoch,
              attachedEpoch == currentEpoch else {
            return "Screenshots belong to an earlier conversation. Remove and reattach them."
        }
        guard let limits = imageLimits(workflow: workflow, operation: operation, now: now) else {
            return "This model or session cannot send screenshots right now. Remove them or switch to a vision-capable model."
        }
        guard limits.accepts(attachments.map(\.attachment), at: now) else {
            return "Screenshots expired or exceed this model's image limits. Remove and reattach them."
        }
        return nil
    }

    func canSend(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> Bool {
        guard !isSending, !isAttaching, pendingOperationId == nil,
              operation.support == .receipts,
              let epoch = operation.conversationEpoch,
              !epoch.isEmpty,
              let workflow,
              workflow.supports(.send, at: now),
              workflow.sendReady,
              SessionInputValidation.isValidPrompt(prompt),
              attachmentsBlockedReason(workflow: workflow, operation: operation, now: now) == nil else {
            return false
        }
        return true
    }

    func syncConversationEpoch(_ currentEpoch: String?) {
        if let currentEpoch, let pendingOperationEpoch, pendingOperationEpoch != currentEpoch {
            pendingOperationId = nil
            self.pendingOperationEpoch = nil
            statusMessage = "The conversation changed. Check the terminal before sending again."
        }
    }

    func reconcileReceipts(
        _ receipts: [RemoteOperationReceipt]?,
        conversationEpoch: String?
    ) {
        syncConversationEpoch(conversationEpoch)
        guard let pendingId = pendingOperationId,
              let receipt = receipts?.first(where: {
                  $0.operationId == pendingId
                      && $0.kind == RemoteSessionActionKind.send.rawValue
                      && ($0.state == .applied || $0.state == .rejected)
              }) else {
            return
        }
        pendingOperationId = nil
        pendingOperationEpoch = nil
        if receipt.state == .applied {
            prompt = ""
            attachments = []
            attachedEpoch = nil
            statusMessage = nil
        } else {
            statusMessage = "Copilot did not accept this message. Review and try again."
        }
    }

    func attachImageData(
        _ rawDataList: [Data],
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) async {
        await attachSources(
            .imagePayloads(rawDataList),
            workflow: workflow,
            operation: operation,
            now: now
        )
    }

    func attachFiles(
        _ urls: [URL],
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) async {
        await attachSources(
            .fileURLs(urls),
            workflow: workflow,
            operation: operation,
            now: now
        )
    }

    @discardableResult
    func pasteFromPasteboard(
        _ pasteboard: NSPasteboard = .general,
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) async -> Bool {
        guard !isSending, !isAttaching, pendingOperationId == nil else {
            statusMessage = "Wait for the current action to finish before attaching screenshots."
            return false
        }
        guard let limits = imageLimits(workflow: workflow, operation: operation, now: now) else {
            statusMessage = "Select a vision-capable model with active native controls before attaching screenshots."
            return false
        }
        let remaining = max(0, limits.maxImages - attachments.count)
        do {
            let source = try DesktopScreenshotAttachmentImage.pasteboardSources(
                from: pasteboard,
                remainingCapacity: remaining,
                maxImages: limits.maxImages
            )
            let beforeCount = attachments.count
            await attachSources(source, workflow: workflow, operation: operation, now: now)
            return attachments.count > beforeCount
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func attachSources(
        _ source: DesktopScreenshotAttachmentImage.PasteboardSource,
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date
    ) async {
        let itemCount: Int = switch source {
        case .fileURLs(let urls): urls.count
        case .imagePayloads(let payloads): payloads.count
        }
        guard itemCount > 0 else { return }
        guard !isSending, !isAttaching, pendingOperationId == nil else {
            statusMessage = "Wait for the current action to finish before attaching screenshots."
            return
        }
        guard let limits = imageLimits(workflow: workflow, operation: operation, now: now),
              let epoch = operation.conversationEpoch else {
            statusMessage = "Select a vision-capable model with active native controls before attaching screenshots."
            return
        }
        if !attachments.isEmpty && attachedEpoch != epoch {
            statusMessage = "Screenshots belong to an earlier conversation. Remove saved screenshots before attaching new ones."
            return
        }
        guard attachments.count + itemCount <= limits.maxImages else {
            statusMessage = "This model allows up to \(limits.maxImages) screenshot(s) per message."
            return
        }
        let targetSessionId = sessionId
        let store = attachmentStore
        attachGeneration &+= 1
        let generation = attachGeneration
        isAttaching = true
        defer {
            if attachGeneration == generation {
                isAttaching = false
            }
        }
        let result: Result<[(RemoteAttachment, DesktopScreenshotAttachmentImage.NormalizedAttachment)], Error> =
            await Task.detached {
                var stored: [(RemoteAttachment, DesktopScreenshotAttachmentImage.NormalizedAttachment)] = []
                do {
                    let payloads: [Data] = switch source {
                    case .fileURLs(let urls):
                        try urls.map(DesktopScreenshotAttachmentImage.readImageFileData)
                    case .imagePayloads(let rawDataList):
                        rawDataList
                    }
                    for rawData in payloads {
                        let normalized = try DesktopScreenshotAttachmentImage.normalized(rawData, limits: limits)
                        let id = UUID().uuidString.lowercased()
                        let metadata = try store.store(
                            normalized.data,
                            id: id,
                            sessionId: targetSessionId,
                            conversationEpoch: epoch,
                            now: now,
                            limits: limits
                        )
                        stored.append((metadata, normalized))
                    }
                    return .success(stored)
                } catch {
                    for (metadata, _) in stored {
                        try? FileManager.default.removeItem(at: store.root.appendingPathComponent("\(metadata.id).image"))
                        try? FileManager.default.removeItem(at: store.root.appendingPathComponent("\(metadata.id).json"))
                    }
                    return .failure(error)
                }
            }.value
        guard attachGeneration == generation else {
            if case .success(let stored) = result {
                for (metadata, _) in stored {
                    removeStoredFiles(id: metadata.id)
                }
            }
            return
        }
        switch result {
        case .success(let stored):
            guard attachments.isEmpty || attachedEpoch == epoch,
                  attachments.count + stored.count <= limits.maxImages else {
                for (metadata, _) in stored {
                    removeStoredFiles(id: metadata.id)
                }
                statusMessage = "The conversation changed while attaching screenshots. Try again."
                return
            }
            if attachments.isEmpty {
                attachedEpoch = epoch
            }
            for (metadata, normalized) in stored {
                attachments.append(makeStagedAttachment(metadata: metadata, normalized: normalized))
            }
            statusMessage = nil
        case .failure(let error):
            statusMessage = error.localizedDescription
        }
    }

    func removeAttachment(id: String) {
        guard !isSending, pendingOperationId == nil else { return }
        attachments.removeAll { $0.id == id }
        removeStoredFiles(id: id)
        if attachments.isEmpty {
            attachedEpoch = nil
        }
        statusMessage = nil
    }

    func clearAttachments(force: Bool = false) {
        guard force || (!isSending && pendingOperationId == nil) else { return }
        let ids = attachments.map(\.id)
        attachGeneration &+= 1
        isAttaching = false
        attachments = []
        attachedEpoch = nil
        statusMessage = nil
        for id in ids {
            removeStoredFiles(id: id)
        }
    }

    func dismissStatusMessage() {
        statusMessage = nil
    }

    func previewItem(for item: StagedAttachment) -> TranscriptImagePreviewItem {
        TranscriptImagePreviewItem(
            id: TranscriptImageIdentity(
                sessionId: sessionId,
                imageId: item.previewImageId,
                version: item.previewVersion
            ),
            data: item.previewPNGData
        )
    }

    func send(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult,
        now: Date = Date()
    ) async {
        syncConversationEpoch(operation.conversationEpoch)
        if let blocked = attachmentsBlockedReason(workflow: workflow, operation: operation, now: now) {
            statusMessage = blocked
            return
        }
        guard canSend(workflow: workflow, operation: operation, now: now),
              let submittedEpoch = operation.conversationEpoch else {
            return
        }
        let action = RemoteSessionAction(
            kind: .send,
            prompt: prompt,
            mode: mode,
            attachmentIds: attachments.isEmpty ? nil : attachments.map(\.id)
        )
        guard action.isValid else {
            statusMessage = "Enter a valid prompt of at most 8,192 UTF-8 bytes."
            return
        }
        isSending = true
        statusMessage = "Waiting for Copilot to confirm..."
        if !attachments.isEmpty {
            let ids = attachments.map(\.id)
            let store = attachmentStore
            let targetSessionId = sessionId
            let verified = await Task.detached {
                ids.allSatisfy { id in
                    (try? store.image(
                        id: id,
                        sessionId: targetSessionId,
                        conversationEpoch: submittedEpoch,
                        now: now
                    )) != nil
                }
            }.value
            guard verified else {
                isSending = false
                statusMessage = "Screenshot is missing or expired. Remove and reattach it."
                return
            }
        }
        let result = await onAction(action)
        isSending = false
        switch result.state {
        case .applied:
            prompt = ""
            attachments = []
            attachedEpoch = nil
            pendingOperationId = nil
            pendingOperationEpoch = nil
            statusMessage = nil
        case .indeterminate:
            pendingOperationId = result.operationId
            pendingOperationEpoch = submittedEpoch
            statusMessage = result.message ?? "Couldn't confirm the outcome. Inspect the terminal before trying again."
        case .rejected, .accepted:
            pendingOperationId = nil
            pendingOperationEpoch = nil
            statusMessage = result.message ?? "Copilot did not accept this message."
        }
    }

    private func makeStagedAttachment(
        metadata: RemoteAttachment,
        normalized: DesktopScreenshotAttachmentImage.NormalizedAttachment
    ) -> StagedAttachment {
        previewSequence &+= 1
        // Keep attachment preview IDs outside Kitty's 24-bit 1...0xFFFFFF namespace.
        let imageId = 0x0100_0000 &+ (previewSequence & 0x00FF_FFFF)
        return StagedAttachment(
            id: metadata.id,
            attachment: metadata,
            data: normalized.data,
            previewPNGData: normalized.previewPNGData,
            previewImageId: imageId,
            previewVersion: UInt64(previewSequence)
        )
    }

    private func removeStoredFiles(id: String) {
        guard RemoteAttachmentContract.validID(id) else { return }
        let fm = FileManager.default
        let imageURL = attachmentStore.root.appendingPathComponent("\(id).image")
        let metadataURL = attachmentStore.root.appendingPathComponent("\(id).json")
        if fm.fileExists(atPath: imageURL.path) {
            try? fm.removeItem(at: imageURL)
        }
        if fm.fileExists(atPath: metadataURL.path) {
            try? fm.removeItem(at: metadataURL)
        }
    }
}

@MainActor
final class CopilotPromptComposer: NSObject, NSTextViewDelegate {
    enum Outcome {
        case started, cancelled, newTerminal
    }

    let alert = NSAlert()
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
    private let instructions = "Write the first prompt for an interactive Copilot session. "
        + "Return adds a line; Command-Return starts Copilot. "
        + "If startup fails, use the tab's Copy Starting Prompt menu before closing the tab or quitting."

    override init() {
        super.init()
        alert.messageText = "Start Copilot with a Prompt"
        alert.addButton(withTitle: "Start Copilot")
        alert.addButton(withTitle: "Cancel")
        let terminalButton = alert.addButton(withTitle: "New Terminal")
        terminalButton.isHidden = true
        terminalButton.keyEquivalent = ""
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalentModifierMask = .command
        alert.buttons[1].keyEquivalent = "\u{1b}"

        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Starting prompt")
        textView.delegate = self

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView
        updateValidation()
    }

    func textDidChange(_ notification: Notification) {
        updateValidation()
    }

    private func updateValidation() {
        let valid = SessionInputValidation.isValidPrompt(textView.string)
        alert.buttons[0].isEnabled = valid
        alert.informativeText = valid || textView.string.isEmpty
            ? instructions
            : "Enter a nonempty prompt of at most 8,192 UTF-8 bytes, without terminal control characters."
    }

    func run(
        present: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() },
        start: @MainActor (String) throws -> Void
    ) -> Outcome {
        var offersTerminal = false
        while true {
            alert.buttons[2].isHidden = !offersTerminal
            alert.layout()
            alert.window.initialFirstResponder = textView
            let response = present(alert)
            if response == .alertThirdButtonReturn, offersTerminal {
                return .newTerminal
            }
            guard response == .alertFirstButtonReturn else { return .cancelled }
            do {
                try start(textView.string)
                return .started
            } catch {
                // Keep the same editor and its text on synchronous launch failures.
                alert.informativeText = error.localizedDescription
                switch error as? AppModel.CopilotSessionStartError {
                case .copilotUnavailable, .backendUnavailable:
                    offersTerminal = true
                default:
                    offersTerminal = false
                }
            }
        }
    }
}
