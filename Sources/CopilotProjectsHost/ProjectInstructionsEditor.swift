import AppKit

@MainActor
final class ProjectInstructionsEditor {
    let alert = NSAlert()
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))

    init(projectName: String, text: String) {
        alert.messageText = "Copilot Instructions"
        alert.informativeText = "Additional instructions for \(projectName), saved only in this app. "
            + "Your personal and repository instructions still apply. "
            + "Restart or resume Copilot after saving; existing turns are unchanged. "
            + "Leave empty to remove. Return adds a line; Command-Return saves."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
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
        textView.setAccessibilityLabel("Additional Copilot instructions for \(projectName)")
        textView.string = text

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView
    }

    func run(
        present: @MainActor (NSAlert) -> NSApplication.ModalResponse,
        isTerminating: @MainActor () -> Bool = { false },
        save: @MainActor (String) throws -> Void
    ) {
        while !isTerminating() {
            alert.layout()
            alert.window.initialFirstResponder = textView
            guard present(alert) == .alertFirstButtonReturn else { return }
            guard !isTerminating() else { return }
            do {
                try save(textView.string)
                return
            } catch {
                alert.informativeText = "Could not save instructions. \(error.localizedDescription)"
                if case AppModel.CopilotSessionStartError.projectUnavailable = error {
                    alert.buttons[0].isEnabled = false
                }
            }
        }
    }
}
