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
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Select Session \(n)") {
                        appDelegate.model.selectSessionByIndex(n - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let notifications = NotificationManager()

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
        model.installCLISymlinkIfPossible()
        CopilotHooks.installIfPossible()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
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
