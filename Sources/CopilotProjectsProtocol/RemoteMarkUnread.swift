import Foundation

/// Remote "Mark as Unread". A gateway advertises `capability` only when it routes
/// `controlType` to a host that implements it, so a client facing an older Mac
/// hides the action rather than sending a command it rejects. The existing
/// `mark-read` control marks the session read again.
public enum RemoteMarkUnreadContract {
    public static let capability = "mark-unread-v1"
    /// `RemoteClientMessage.type` for the control POST. Only `sessionId` is read.
    public static let controlType = "mark-unread"
}
