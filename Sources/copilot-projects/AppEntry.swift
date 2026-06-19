import SwiftUI
import AppKit
import CopilotProjectsCore

struct CopilotProjectsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Copilot Projects", id: "main") {
            RootView(model: appDelegate.model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { appDelegate.model.addProjectInteractive() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Session") {
                Button("New Session") { appDelegate.model.addSessionToSelected() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Session") { appDelegate.model.closeSelectedSession() }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Next Session") { appDelegate.model.selectAdjacentSession(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Session") { appDelegate.model.selectAdjacentSession(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let notifications = NotificationManager()
    private var eventMonitor: Any?
    private var hintWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false

        notifications.onActivate = { [weak self] projectId, sessionId in
            self?.model.focus(projectId: projectId, sessionId: sessionId)
        }
        notifications.requestAuth()

        model.attach(notifications: notifications)
        model.bootstrapIfNeeded()
        model.startServer()
        model.startLivenessReconciler()
        // A test/isolated instance can opt out of mutating the user's CLI + hooks.
        let env = ProcessInfo.processInfo.environment
        if (env["COPILOT_PROJECTS_NO_INSTALL"] ?? env["COPILOT_MUX_NO_INSTALL"]) != "1" {
            model.installCLISymlinkIfPossible()
            CopilotHooks.installIfPossible()
        }

        NSApp.activate(ignoringOtherApps: true)

        // ⌘/⌃ + number navigation, the modifier-hold number overlay, double-click
        // title-bar zoom, link-vs-selection disambiguation, and scroll-wheel
        // forwarding into mouse-reporting TUIs.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .scrollWheel, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }

        // If focus leaves the app while a modifier is held (e.g. ⌘-Tab away), the
        // local monitor stops receiving the matching key-up, so the number overlay
        // would stay stuck. Clear it whenever we resign active.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hintWork?.cancel()
                self?.model.setNumberHint(.none)
            }
        }

        // When the app is activated (clicked / ⌘-Tab'd back), put keyboard focus
        // on the visible terminal instead of the sidebar list.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.markActiveSessionSeen()
                self?.model.focusActiveTerminal()
            }
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            // Forward the wheel into the active terminal (mouse-reporting TUI,
            // alt-screen pager, or normal scrollback); otherwise pass it through.
            if let c = model.activeController,
               c.terminalView.containsPointer(for: event),
               c.terminalView.forwardScroll(event, agentLive: model.liveAgentSessions.contains(c.sessionId)) {
                return nil
            }
            return event
        case .flagsChanged:
            updateNumberHint(event.modifierFlags)
            return event
        case .keyDown:
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // ⌘W closes the current tab. (macOS's default ⌘W closes the *window*,
            // which quits the app — that's the accidental-quit footgun.)
            if mods == .command, event.charactersIgnoringModifiers == "w" {
                model.closeSelectedSession()
                return nil
            }
            // Control+Tab / Control+Shift+Tab cycle tabs (browser-style). Keep the
            // overlay up if it's showing so you can keep cycling while holding ⌃.
            if event.keyCode == 48 {  // Tab
                if mods == .control { model.selectAdjacentSession(1); return nil }
                if mods == [.control, .shift] { model.selectAdjacentSession(-1); return nil }
            }
            // ⌘ / ⌃ + number jumps to a project / tab.
            if let digit = Self.digit(from: event) {
                if mods == .command {
                    hintWork?.cancel(); model.setNumberHint(.none)
                    model.selectProjectByIndex(digit - 1); return nil
                }
                if mods == .control {
                    hintWork?.cancel(); model.setNumberHint(.none)
                    model.selectSessionByIndex(digit - 1); return nil
                }
            }
            // Any other key dismisses the overlay.
            hintWork?.cancel()
            model.setNumberHint(.none)
            return event
        case .leftMouseDown:
            // Double-click the top title strip (but not the traffic lights) to run
            // the user's title-bar double-click action; .hiddenTitleBar + our
            // SwiftUI strip otherwise swallows the native gesture.
            if event.clickCount == 2, let window = event.window, isInTitleStrip(event, window: window) {
                performTitleBarDoubleClick(window)
                return nil
            }
            return event
        case .leftMouseUp:
            // SwiftTerm opens the link under the release point on mouseUp (in
            // `.hover`, explicit OR bare URL) with no guard for whether the user was
            // selecting text — so dragging to select a URL (to copy it) would open
            // the browser. SwiftTerm can't be subclassed here (its mouse methods are
            // `public`, not `open`), so disambiguate from this monitor, which runs
            // before the view's own mouseUp: if a selection is active at release (a
            // drag or double/triple-click — a plain click clears it in mouseDown),
            // briefly require ⌘ so SwiftTerm finds no clickable link, then restore.
            if let c = model.activeController, c.terminalView.selectionActive,
               !event.modifierFlags.contains(.command) {
                let tv = c.terminalView
                tv.linkHighlightMode = .hoverWithModifier
                DispatchQueue.main.async { tv.linkHighlightMode = .hover }
            }
            return event
        default:
            return event
        }
    }

    /// True when the pointer is in the top title strip (matching RootView's 38pt
    /// titleStripHeight), past the traffic lights.
    private func isInTitleStrip(_ event: NSEvent, window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        let p = content.convert(event.locationInWindow, from: nil)
        let yFromTop = content.bounds.height - p.y
        return yFromTop >= 0 && yFromTop <= 38 && p.x > 80
    }

    /// Mirror the system "double-click a window's title bar to" preference
    /// (System Settings ▸ Desktop & Dock); defaults to zoom when unset/unknown.
    private func performTitleBarDoubleClick(_ window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }

    private func updateNumberHint(_ flags: NSEvent.ModifierFlags) {
        let mods = flags.intersection([.command, .control, .option, .shift])
        let target: NumberHint = mods == .command ? .projects : (mods == .control ? .tabs : .none)
        hintWork?.cancel()
        guard target != .none else {
            model.setNumberHint(.none)
            return
        }
        // Brief delay so quick combos (⌘C, ⌘T…) don't flash the overlay.
        let work = DispatchWorkItem { [weak self] in self?.model.setNumberHint(target) }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private static func digit(from event: NSEvent) -> Int? {
        guard let s = event.charactersIgnoringModifiers, s.count == 1,
              let n = Int(s), (1...9).contains(n) else { return nil }
        return n
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.beginTermination()
        model.detachAllClients()   // keep dtach masters alive for resume
        model.stopServer()
        model.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
