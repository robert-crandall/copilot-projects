import AppKit
import Darwin
import SwiftUI
import UserNotifications
import CopilotProjectsCore

/// Copilot Notifications: the user's GitHub inbox as its own app. It keeps
/// running after its window closes, like Mail, so its Dock badge and banners
/// stay current.
@MainActor
public enum NotificationsApplication {
    /// Held for the process's lifetime by the one copy that writes the state.
    static var lock: PullRequestsAppLock?
    static var lockFailure: String?
    /// Copilot Projects started this copy to watch, not to show anything.
    static var startsInBackground = false

    static var isPrimary: Bool { lock != nil }
    /// Another copy holds the lock, so this one only brings it forward.
    static var handsOff: Bool { lock == nil && lockFailure == nil }

    public static func run() {
        signal(SIGPIPE, SIG_IGN)
        startsInBackground = CommandLine.arguments.contains(NotificationsAppBundle.backgroundArgument)
        let candidate = PullRequestsAppLock(lockPath: Paths.notificationsAppLockPath, pidPath: Paths.notificationsAppPIDPath)
        switch candidate.acquire() {
        case .acquired:
            lock = candidate
        case .heldElsewhere:
            break
        case .failed(let code):
            NSLog("copilot-notifications: could not lock \(candidate.lockPath), errno \(code); saving nothing")
            lockFailure = failureNote(errno: code)
        }
        let app = NSApplication.shared
        let delegate = NotificationsAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    static func failureNote(errno code: Int32) -> String {
        "Looks and banner settings aren’t saved in this copy: its state folder can’t be locked (\(String(cString: strerror(code))))"
    }
}

@MainActor
final class NotificationsAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NotificationBannerPosting {
    let model: NotificationsModel
    private var window: NSWindow?
    private var eventMonitor: Any?
    private let banners = NotificationsBannerCenter()

    override init() {
        let primary = NotificationsApplication.isPrimary
        model = NotificationsModel(
            workspace: ControlWorkspaceBridge(),
            host: .system(),
            writesState: primary,
            storageNote: NotificationsApplication.lockFailure,
            summaryURL: primary ? Paths.notificationsSummaryURL : nil,
            stateDirectory: Paths.notificationsStateDir,
            isVisible: {
                NSApp.windows.contains { TitleStrip.applies(to: $0) && $0.isVisible && !$0.isMiniaturized }
            }
        )
        super.init()
        model.banners = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = Self.mainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NotificationsApplication.handsOff {
            if !NotificationsApplication.startsInBackground { bringRunningCopyForward() }
            // The window request travels through the distributed notification
            // server; exiting at once can drop it on the way out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        // With no window open AppKit would let the system quit this copy
        // silently, taking the Dock badge and banners with it.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        ProcessInfo.processInfo.disableAutomaticTermination("Watching GitHub notifications")
        // The hidden title bar leaves the drag strip to SwiftUI, which swallows
        // the native double-click; run the user's title-bar action from here.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, let window = event.window, TitleStrip.applies(to: window),
                  TitleStrip.contains(event.locationInWindow, windowHeight: window.frame.height) else { return event }
            TitleStrip.performDoubleClickAction(window)
            return nil
        }
        banners.onOpen = { [weak self] key, url in
            guard let self else { return }
            if key == nil, url == nil { self.showWindow() } else { self.model.openBanner(thread: key, url: url) }
        }
        banners.onAuthorization = { [weak self] allowed in self?.model.bannersAllowed = allowed }
        banners.requestAuthorization()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(windowRequested(_:)), name: NotificationsAppBundle.showWindowNotification,
            object: NotificationsAppBundle.windowRequestObject(), suspensionBehavior: .deliverImmediately
        )
        model.start()
        if !NotificationsApplication.startsInBackground { showWindow() }
    }

    /// Copilot Projects, or a second copy handing off, asked for the window.
    @objc nonisolated private func windowRequested(_ notification: Notification) {
        MainActor.assumeIsolated { showWindow() }
    }

    @objc private func showWindowFromMenu(_ sender: Any?) { showWindow() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon, opening from Copilot Projects, or a second copy
    /// handing off all bring the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    /// Activation alone never opens the window: a banner click activates the
    /// app on its way to the browser. Opening from Copilot Projects, the Dock,
    /// or Window ▸ Notifications does.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !NotificationsApplication.handsOff else { return }
        banners.refreshAuthorization()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.finishedLooking()
        NotificationsApplication.lock?.release()
    }

    func post(_ banners: [NotificationBanner]) {
        self.banners.post(banners)
    }

    // MARK: Window

    func showWindow() {
        let window = self.window ?? makeWindow()
        self.window = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = NotificationsAppBundle.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 880, height: 480)
        window.contentView = NSHostingView(rootView: NotificationsView(model: model))
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    private static let frameName = "CopilotNotificationsWindow"

    func windowDidBecomeKey(_ notification: Notification) {
        model.beganLooking()
        model.refreshIfStale()
    }

    func windowDidResignKey(_ notification: Notification) { model.finishedLooking() }

    func windowWillClose(_ notification: Notification) { model.finishedLooking() }

    /// The app, Edit, and Window menus; the window has no File or View menus to offer.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(NotificationsAppBundle.name)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(NotificationsAppBundle.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(NotificationsAppBundle.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Notifications", action: #selector(NotificationsAppDelegate.showWindowFromMenu(_:)), keyEquivalent: "0")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }

    private func bringRunningCopyForward() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
        guard let pid = PullRequestsAppDelegate.copyToBringForward(
                recorded: PullRequestsAppLock.recordedProcessIdentifier(at: Paths.notificationsAppPIDPath),
                others: others.map { ($0.processIdentifier, $0.bundleURL == Bundle.main.bundleURL) }
              ),
              let running = others.first(where: { $0.processIdentifier == pid }) else {
            NSLog("copilot-notifications: another copy holds the lock but couldn't be found")
            return
        }
        NotificationsAppBundle.requestWindow()
        _ = running.activate(from: .current, options: [])
    }
}

/// Posts banners through the user notification center and routes clicks back.
@MainActor
final class NotificationsBannerCenter: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((NotificationThread.Key?, URL?) -> Void)?
    var onAuthorization: ((Bool) -> Void)?

    nonisolated private static let accountKey = "account"
    nonisolated private static let threadKey = "thread"
    nonisolated private static let urlKey = "url"

    /// The notification center needs an app bundle; a bare development build has none.
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func requestAuthorization() {
        guard available else {
            onAuthorization?(false)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error { NSLog("copilot-notifications: banner authorization failed: \(error)") }
            Task { @MainActor in self?.onAuthorization?(granted) }
        }
    }

    func refreshAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in self?.onAuthorization?(allowed) }
        }
    }

    func post(_ banners: [NotificationBanner]) {
        guard available else { return }
        for banner in banners {
            let content = UNMutableNotificationContent()
            content.title = banner.title
            if let subtitle = banner.subtitle { content.subtitle = subtitle }
            content.body = banner.body
            content.sound = .default
            content.threadIdentifier = "notifications"
            var info: [String: String] = [:]
            if let thread = banner.thread {
                info[Self.accountKey] = thread.account
                info[Self.threadKey] = thread.id
            }
            if let url = banner.url { info[Self.urlKey] = url.absoluteString }
            content.userInfo = info
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: banner.identifier, content: content, trigger: nil)
            ) { error in
                if let error { NSLog("copilot-notifications: could not post a banner: \(error)") }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let account = info[Self.accountKey] as? String
        let thread = info[Self.threadKey] as? String
        let url = (info[Self.urlKey] as? String).flatMap(URL.init(string:))
        Task { @MainActor in
            let key = account.flatMap { account in thread.map { NotificationThread.Key(account: account, id: $0) } }
            self.onOpen?(key, url)
            completionHandler()
        }
    }

    /// Banners raised while the window is in front would repeat what it shows.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            let looking = NSApp.isActive && NSApp.keyWindow.map(TitleStrip.applies(to:)) == true
            completionHandler(looking ? [] : [.banner, .sound, .list])
        }
    }
}
