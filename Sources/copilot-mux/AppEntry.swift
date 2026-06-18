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
                Button("New Session") { appDelegate.model.addSessionToSelected() }
                    .keyboardShortcut("t", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Session") { appDelegate.model.closeSelectedSession() }
                    .keyboardShortcut("w", modifiers: .command)
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

        notifications.onActivate = { [weak self] projectId, sessionId in
            self?.model.focus(projectId: projectId, sessionId: sessionId)
        }
        notifications.requestAuth()

        model.attach(notifications: notifications)
        model.bootstrapIfNeeded()
        model.startServer()
        model.installCLISymlinkIfPossible()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopServer()
        model.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
