import Foundation

/// A cheap file-identity fingerprint (inode + size + mtime) used to detect whether
/// a file's contents can have changed, so an unchanged file can be served from an
/// in-memory cache instead of being re-read and re-decoded. Shared by the
/// agent-activity snapshot cache (`AppModel`) and the transcript reload path
/// (`TranscriptController`).
struct FileSignature: Equatable, Sendable {
    let size: UInt64
    let modifiedAt: TimeInterval
    let fileNumber: UInt64

    /// Build a signature from a `FileManager.attributesOfItem(atPath:)` dictionary.
    init(attributes: [FileAttributeKey: Any]) {
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modifiedAt = (attributes[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
