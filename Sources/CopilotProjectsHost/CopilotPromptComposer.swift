import AppKit
import CopilotProjectsCore

struct ResumableSessionCandidate: Equatable, Identifiable, Sendable {
    let entry: SessionFinderEntry
    let reason: String

    var id: String { entry.id }
    var copilotSessionId: String? { entry.source.resumableCopilotSessionId }
    var title: String { entry.source.title }
    var cwd: String { entry.source.cwd }
    var folderName: String { entry.folderName }
    var lastActivity: Date? { entry.lastActivity }
}

@MainActor
final class CopilotPromptComposer: NSObject, NSTextViewDelegate {
    struct Configuration {
        var title: String
        var confirmButtonTitle: String
        var instructions: String
        var accessibilityLabel: String
        var initialText: String

        static let startSession = Configuration(
            title: "Start Copilot with a Prompt",
            confirmButtonTitle: "Start Copilot",
            instructions: "Write the first prompt for an interactive Copilot session. "
                + "Return adds a line; Command-Return starts Copilot. "
                + "If startup fails, use the tab's Copy Starting Prompt menu before closing the tab or quitting.",
            accessibilityLabel: "Starting prompt",
            initialText: ""
        )

        static func resumeSession(projectName: String, initialText: String = "") -> Configuration {
            Configuration(
                title: "Resume Copilot Session",
                confirmButtonTitle: "Resume Session",
                instructions: "Describe the ended Copilot session to find and resume in “\(projectName)”. "
                    + "Return adds a line; Command-Return searches with the Copilot CLI.",
                accessibilityLabel: "Session search prompt",
                initialText: initialText
            )
        }
    }

    enum Outcome {
        case started, cancelled, newTerminal
    }

    let alert = NSAlert()
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
    private let configuration: Configuration

    convenience override init() {
        self.init(configuration: .startSession)
    }

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
        alert.messageText = configuration.title
        alert.addButton(withTitle: configuration.confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        let terminalButton = alert.addButton(withTitle: "New Terminal")
        terminalButton.isHidden = true
        terminalButton.keyEquivalent = ""
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
        textView.setAccessibilityLabel(configuration.accessibilityLabel)
        textView.string = configuration.initialText
        textView.delegate = self

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView
        updateValidation()
    }

    func textDidChange(_ notification: Notification) {
        updateValidation()
    }

    private func updateValidation() {
        let valid = SessionInputValidation.isValidPrompt(textView.string)
        alert.buttons[0].isEnabled = valid
        alert.informativeText = valid || textView.string.isEmpty
            ? configuration.instructions
            : "Enter a nonempty prompt of at most 8,192 UTF-8 bytes, without terminal control characters."
    }

    func run(
        present: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() },
        start: (String) throws -> Void
    ) -> Outcome {
        var offersTerminal = false
        while true {
            alert.buttons[2].isHidden = !offersTerminal
            alert.layout()
            alert.window.initialFirstResponder = textView
            let response = present(alert)
            if response == .alertThirdButtonReturn, offersTerminal {
                return .newTerminal
            }
            guard response == .alertFirstButtonReturn else { return .cancelled }
            do {
                try start(textView.string)
                return .started
            } catch {
                // Keep the same editor and its text on synchronous launch failures.
                alert.informativeText = error.localizedDescription
                switch error as? AppModel.CopilotSessionStartError {
                case .copilotUnavailable, .backendUnavailable:
                    offersTerminal = true
                default:
                    offersTerminal = false
                }
            }
        }
    }
}

/// Modal picker shown when a prompt-based session search matches multiple ended sessions.
@MainActor
final class SessionResumeMatchPicker: NSObject {
    enum Outcome: Equatable {
        case resume(ResumableSessionCandidate)
        case editPrompt
        case cancelled
    }

    let alert = NSAlert()
    let matches: [ResumableSessionCandidate]
    private(set) var selectedIndex: Int = 0
    private var radioButtons: [NSButton] = []

    init(projectName: String, matches: [ResumableSessionCandidate], now: Date = Date()) {
        self.matches = matches
        super.init()
        alert.messageText = "Multiple Matching Sessions"
        alert.informativeText = "More than one ended Copilot session matched your prompt. "
            + "Choose which session to resume in “\(projectName)”."
        alert.addButton(withTitle: "Resume Session")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Edit Prompt…")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.buttons[2].keyEquivalent = ""

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, candidate) in matches.enumerated() {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2

            let button = NSButton(
                radioButtonWithTitle: candidate.title,
                target: self,
                action: #selector(radioClicked(_:))
            )
            button.tag = index
            button.state = index == 0 ? .on : .off
            button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            button.lineBreakMode = .byTruncatingTail
            radioButtons.append(button)
            row.addArrangedSubview(button)

            var detailParts: [String] = []
            if !candidate.folderName.isEmpty, candidate.folderName != "/" {
                detailParts.append(candidate.folderName)
            }
            if let lastActivity = candidate.lastActivity {
                detailParts.append(LunaSessionPrompt.relative(lastActivity, now: now))
            }
            if !candidate.reason.isEmpty {
                detailParts.append(candidate.reason)
            }
            if !detailParts.isEmpty {
                let caption = NSTextField(labelWithString: detailParts.joined(separator: " · "))
                caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                caption.textColor = .secondaryLabelColor
                caption.lineBreakMode = .byTruncatingTail
                caption.maximumNumberOfLines = 2
                row.addArrangedSubview(caption)
            }

            stack.addArrangedSubview(row)
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: max(80, CGFloat(matches.count) * 44)))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 440),
        ])
        alert.accessoryView = container
        alert.buttons[0].isEnabled = !matches.isEmpty
    }

    func select(index: Int) {
        guard matches.indices.contains(index) else { return }
        selectedIndex = index
        for (buttonIndex, button) in radioButtons.enumerated() {
            button.state = buttonIndex == index ? .on : .off
        }
    }

    @objc private func radioClicked(_ sender: NSButton) {
        select(index: sender.tag)
    }

    func run(
        present: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    ) -> Outcome {
        alert.layout()
        switch present(alert) {
        case .alertFirstButtonReturn:
            guard matches.indices.contains(selectedIndex) else { return .cancelled }
            return .resume(matches[selectedIndex])
        case .alertThirdButtonReturn:
            return .editPrompt
        default:
            return .cancelled
        }
    }
}
