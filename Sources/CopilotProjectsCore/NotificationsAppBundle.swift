import Foundation

/// Where the Copilot Notifications app lives and what crosses into it. It
/// travels with Copilot Pull Requests: same environment, same isolation rule.
public enum NotificationsAppBundle {
    public static let name = "Copilot Notifications"
    /// Appended to the host's bundle identifier.
    public static let bundleIdentifierSuffix = ".notifications"
    /// Passed when Copilot Projects starts it to watch in the background: it
    /// opens with no window, only its Dock badge and banners.
    public static let backgroundArgument = "--background"

    /// `Copilot Projects.app/Contents/Helpers/Copilot Notifications.app`.
    public static func helperURL(inHostBundle hostURL: URL) -> URL {
        hostURL.appendingPathComponent("Contents/Helpers/\(name).app", isDirectory: true)
    }

    public static func helperBundleIdentifier(hostBundleIdentifier: String) -> String {
        hostBundleIdentifier + bundleIdentifierSuffix
    }

    #if os(macOS)
    /// Asks the running copy for `stateDirectory` to show its window. Activation
    /// alone can't: the app keeps running with no window, and a banner click
    /// activates it without wanting one.
    public static let showWindowNotification = Notification.Name("CopilotNotificationsShowWindow")

    public static func requestWindow(stateDirectory: URL = Paths.notificationsStateDir) {
        DistributedNotificationCenter.default().postNotificationName(
            showWindowNotification, object: windowRequestObject(stateDirectory),
            userInfo: nil, deliverImmediately: true
        )
    }

    public static func windowRequestObject(_ stateDirectory: URL = Paths.notificationsStateDir) -> String {
        stateDirectory.standardizedFileURL.path
    }
    #endif
}

/// What Copilot Notifications publishes for Copilot Projects' menu bar item.
public struct NotificationsSummary: Codable, Equatable, Sendable {
    /// Unread threads that need the user: to them, via their teams, or watched.
    public var needsYou: Int
    public var toYou: Int
    public var viaTeams: Int
    public var watching: Int
    public var updatedAt: Date

    public init(needsYou: Int, toYou: Int, viaTeams: Int, watching: Int, updatedAt: Date) {
        self.needsYou = needsYou
        self.toYou = toYou
        self.viaTeams = viaTeams
        self.watching = watching
        self.updatedAt = updatedAt
    }

    /// A summary older than this is from a copy that stopped watching.
    public static let freshness: TimeInterval = 15 * 60

    public static func read(from url: URL = Paths.notificationsSummaryURL) -> NotificationsSummary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(NotificationsSummary.self, from: data)
    }

    public func write(to url: URL = Paths.notificationsSummaryURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try encoder.encode(self).write(to: url, options: [.atomic])
    }
}

extension Paths {
    /// The Notifications app's lock, pid, transcript index, and published summary.
    public static var notificationsStateDir: URL {
        notificationsStateDir(stateDir: stateDir, socketPath: socketPath)
    }

    /// Split by socket exactly as the Pull Requests app's state is, so a
    /// Copilot Projects on another socket gets its own Notifications app.
    public static func notificationsStateDir(stateDir: URL, socketPath: String) -> URL {
        let base = stateDir.appendingPathComponent("notifications", isDirectory: true)
        let pullRequests = pullRequestsStateDir(stateDir: stateDir, socketPath: socketPath)
        guard pullRequests.lastPathComponent != "pull-requests" else { return base }
        return base.appendingPathComponent(pullRequests.lastPathComponent, isDirectory: true)
    }

    public static var notificationsAppLockPath: String {
        notificationsStateDir.appendingPathComponent("app.lock").path
    }

    public static var notificationsAppPIDPath: String {
        notificationsStateDir.appendingPathComponent("app.pid").path
    }

    public static var notificationsSummaryURL: URL {
        notificationsStateDir.appendingPathComponent("summary.json")
    }
}
