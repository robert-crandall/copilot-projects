import Foundation

public struct TranscriptSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let updatedAt: Date
    public let copilotSessionId: String
    public let turns: [TranscriptTurn]

    public init(
        schemaVersion: Int,
        updatedAt: Date,
        copilotSessionId: String,
        turns: [TranscriptTurn]
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.copilotSessionId = copilotSessionId
        self.turns = turns
    }
}

public struct TranscriptTurn: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date?
    public let kind: String
    public let userContent: String
    public let assistantMessages: [TranscriptAssistantMessage]
    public let tools: [TranscriptTool]
    public let isAborted: Bool
    /// Inline Kitty images the host associated with this turn (the currently
    /// retained captures whose display time fell within this turn). Absent in
    /// the CLI-written snapshot and populated only by the host before serving
    /// remote clients; optional so older clients (and the CLI writer) ignore it.
    public let images: [TranscriptImageRef]?

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date?,
        kind: String,
        userContent: String,
        assistantMessages: [TranscriptAssistantMessage],
        tools: [TranscriptTool],
        isAborted: Bool,
        images: [TranscriptImageRef]? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.kind = kind
        self.userContent = userContent
        self.assistantMessages = assistantMessages
        self.tools = tools
        self.isAborted = isAborted
        self.images = images
    }
}

/// A reference to one currently-retained inline Kitty image, as associated with
/// a transcript turn. Carries the exact `(imageId, contentVersion)` needed to
/// fetch the bytes via `RemoteTerminalImageContract.path`
/// (`/terminal-image?s=&i=&v=`). `contentVersionText` is the decimal string form
/// of `contentVersion` for JavaScript clients, which cannot represent the full
/// `UInt64` range exactly (it carries a random 32-bit epoch in its high bits);
/// mirrors `RemoteTerminalImagePlacement`'s own JS-safe version handling.
public struct TranscriptImageRef: Codable, Equatable, Sendable {
    public let imageId: UInt32
    public let contentVersion: UInt64
    public let contentVersionText: String

    public init(imageId: UInt32, contentVersion: UInt64) {
        self.imageId = imageId
        self.contentVersion = contentVersion
        self.contentVersionText = String(contentVersion)
    }
}

public struct TranscriptAssistantMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let content: String

    public init(id: String, timestamp: Date, content: String) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
    }
}

public struct TranscriptTool: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let title: String
    public let success: Bool?

    public init(id: String, name: String, title: String, success: Bool?) {
        self.id = id
        self.name = name
        self.title = title
        self.success = success
    }
}

public struct RemoteTranscriptRevision: Codable, Equatable, Sendable {
    public let sessionId: String
    public let generation: String

    public init(sessionId: String, generation: String) {
        self.sessionId = sessionId
        self.generation = generation
    }
}
