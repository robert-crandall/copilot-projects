import SwiftUI
import AppKit
import CopilotProjectsProtocol

struct ConversationView: View {
    @ObservedObject var model: AppModel
    let sessionId: String
    @ObservedObject var controller: TranscriptController
    let onPreview: (TranscriptImagePreviewItem) -> Void

    @State private var mode: RemotePromptMode = .enqueue
    @State private var confirmingUnlock = false

    private var session: Session? { model.conversationSession(sessionId) }
    private var pending: PendingConversationSend? { session?.pendingConversationSend }

    var body: some View {
        VStack(spacing: 0) {
            let workflow = model.sessionWorkflow(sessionId: sessionId)
            let operation = model.sessionOperationProjection(sessionId: sessionId)
            let activity = session?.agentActivity

            if let reason = terminalReason(activity: activity, operation: operation) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(StudioStyle.secondaryText)
                    Text(reason).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open Terminal") {
                        model.setSessionSurface(.terminal, sessionId: sessionId)
                    }
                }
                .padding(12)
                .background(StudioStyle.raised)
                Divider()
            }

            TranscriptOverlay(
                controller: controller,
                imageCapture: { model.terminalView(for: sessionId)?.kittyImageCapture },
                isOpen: true, onClose: {},
                workflow: workflow, operation: operation,
                onAction: { action in
                    await model.performLocalSessionAction(sessionId: sessionId, action: action)
                },
                onPreview: onPreview,
                isConversation: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let pending {
                    HStack {
                        Text(pending.uncertain
                             ? "Send outcome unknown. Inspect Terminal before unlocking. Sending again may duplicate it."
                             : "Waiting for Copilot to confirm this send. You can keep editing this draft.")
                            .font(.callout)
                            .foregroundStyle(pending.uncertain ? .orange : StudioStyle.secondaryText)
                        Spacer()
                        if pending.uncertain, model.hasInspectedUncertainSend(sessionId: sessionId) {
                            Button("Unlock draft") { confirmingUnlock = true }
                        } else if pending.uncertain {
                            Button("Open Terminal") {
                                model.setSessionSurface(.terminal, sessionId: sessionId)
                            }
                        }
                    }
                }
                if let error = model.conversationErrors[sessionId] {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                ConversationEditor(model: model, sessionId: sessionId, text: Binding(
                    get: { model.conversationSession(sessionId)?.conversationDraft ?? "" },
                    set: { model.setConversationDraft($0, sessionId: sessionId) }
                ), onSend: send)
                .frame(height: 100)
                .accessibilityIdentifier("conversation-composer")
                if let count = session?.conversationDraft.utf8.count, count > 8_192 {
                    Text("\(count) / 8,192 UTF-8 bytes. Shorten this prompt before sending.")
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Picker("Delivery", selection: $mode) {
                        ForEach(RemotePromptMode.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button("Send") { send() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(pending != nil || !canSend)
                        .accessibilityIdentifier("conversation-send")
                }
                Text("Return for newline, Command-Return to send")
                    .font(.caption)
                    .foregroundStyle(StudioStyle.secondaryText)
            }
            .padding(14)
            .background(StudioStyle.raised)
        }
        .background(StudioStyle.chrome)
        .confirmationDialog(
            "Unlock without confirmed delivery?",
            isPresented: $confirmingUnlock
        ) {
            Button("Unlock draft (may duplicate send)") {
                model.unlockConversationSendAfterInspection(sessionId: sessionId)
            }

            Button("Keep locked", role: .cancel) {}
        } message: {
            Text("Only unlock after inspecting Terminal. Your draft stays intact, but sending it again could duplicate a request Copilot already received.")
        }
    }

    private var canSend: Bool {
        let text = session?.conversationDraft ?? ""
        return RemoteSessionAction(kind: .send, prompt: text, mode: mode).isValid
            && model.sessionWorkflow(sessionId: sessionId)?.supports(.send, at: Date()) == true
            && model.sessionWorkflow(sessionId: sessionId)?.sendReady == true
            && session?.hasPendingInput != true
    }

    private func send() {
        guard pending == nil, canSend else { return }
        _ = model.sendConversationDraft(sessionId: sessionId, mode: mode)
    }

    private func terminalReason(
        activity: AgentActivitySnapshot?, operation: AgentOperationProjection
    ) -> String? {
        if activity?.pendingPermissionRequestIds?.isEmpty == false {
            return "Copilot needs permission. Open Terminal to review the request."
        }
        if activity?.trackedUserInputs?.isEmpty == false || activity?.trackedElicitations?.isEmpty == false {
            return "Copilot is waiting for your answer. Open Terminal to respond."
        }
        if activity?.workflow?.budgetRequest != nil {
            return "Copilot needs a budget decision. Expand Usage and background work below or open Terminal."
        }
        if activity?.reportsTerminalDisconnect == true {
            return "The Copilot tracker is disconnected. Inspect or reconnect in Terminal."
        }
        if operation.support != .receipts {
            return "Native session controls are unavailable for this session. Use Terminal to inspect or interact."
        }
        if activity?.workflow?.supports(.send) != true || activity?.workflow?.sendReady != true {
            return "Native sending is not ready. Open Terminal to check Copilot's status."
        }
        return nil
    }
}

private struct ConversationEditor: NSViewRepresentable {
    let model: AppModel
    let sessionId: String
    @Binding var text: String
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = ComposerTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 4, height: 6)
        editor.setAccessibilityLabel("Message to Copilot")
        editor.setAccessibilityIdentifier("conversation-composer")
        editor.delegate = context.coordinator
        editor.onSend = onSend
        editor.string = text
        scroll.documentView = editor
        model.registerComposer(editor, sessionId: sessionId)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        model.registerComposer(editor, sessionId: sessionId)
        editor.onSend = onSend
        if editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let editor = scroll.documentView as? ComposerTextView {
            coordinator.parent.model.unregisterComposer(editor)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConversationEditor
        init(_ parent: ConversationEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

private final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    private let editingUndoManager = UndoManager()
    override var undoManager: UndoManager? { editingUndoManager }

    @objc func undo(_ sender: Any?) {
        guard editingUndoManager.canUndo else { return }
        editingUndoManager.undo()
        didChangeText()
    }

    @objc func redo(_ sender: Any?) {
        guard editingUndoManager.canRedo else { return }
        editingUndoManager.redo()
        didChangeText()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            onSend?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  window.attachedSheet == nil else { return }
            window.makeFirstResponder(self)
        }
    }
}
