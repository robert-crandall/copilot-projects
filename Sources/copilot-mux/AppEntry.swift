import SwiftUI
import AppKit
import CopilotMuxCore

struct CopilotMuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Copilot Mux", id: "main") {
            RootView(model: appDelegate.model)
                .frame(minWidth: 820, minHeight: 520)
        }
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
        if ProcessInfo.processInfo.environment["COPILOT_MUX_NO_INSTALL"] != "1" {
            model.installCLISymlinkIfPossible()
            CopilotHooks.installIfPossible()
        }

        NSApp.activate(ignoringOtherApps: true)

        // ⌘/⌃ + number navigation, and the modifier-hold number overlay.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            updateNumberHint(event.modifierFlags)
            return event
        case .keyDown:
            hintWork?.cancel()
            model.setNumberHint(.none)
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if let digit = Self.digit(from: event) {
                if mods == .command { model.selectProjectByIndex(digit - 1); return nil }
                if mods == .control { model.selectSessionByIndex(digit - 1); return nil }
            }
            return event
        default:
            return event
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = model.activeSessionCount
        guard active > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = active == 1 ? "A session is still working" : "\(active) sessions are still working"
        alert.informativeText = "Quitting copilot-mux ends them. Quit anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
