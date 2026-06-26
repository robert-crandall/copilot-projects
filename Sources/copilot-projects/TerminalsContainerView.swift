import SwiftUI
import AppKit
import SwiftTerm

/// One long-lived AppKit view that hosts EVERY session's terminal across all
/// projects. Modeled on Ghostty's surface hosting: the terminal NSViews are owned
/// outside SwiftUI, never torn down on a project/tab switch, and never hidden via
/// opacity. The selected session's terminal is brought to the front — its opaque
/// background covers the rest — while the others keep rendering underneath, so a
/// tab that streamed while in the background is already painted when revealed.
///
/// This replaces the SwiftUI `ZStack`-of-`TerminalHostView` approach. That version
/// kept only the *selected project's* panes mounted, so switching projects made
/// SwiftUI unmount/remount the terminal views (the cross-project repaint flash) and
/// relied on opacity/zIndex tricks within a project. Here SwiftUI never mounts or
/// unmounts a terminal view at all: selection is just a z-order change on a
/// container that always stays in the window.
final class TerminalsContainerView: NSView {
    /// sessionId -> hosted terminal view. Reconciled against the live controllers
    /// on every `sync`.
    private var hosted: [String: ProjectsTerminalView] = [:]
    /// Opaque empty-state view, shown frontmost when no session is selected. Keeps a
    /// covered terminal from ever being revealed stale and gives the empty/no-project
    /// state a real affordance without a SwiftUI overlay punching through the NSView.
    private let cover = EmptyStateView()
    private var activeId: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Clip each terminal's reserved-scroller overhang (we inflate the terminal's
        // width below so the hidden scrollbar column falls off the right edge) — the
        // SwiftUI host used `.clipped()` for this.
        layer?.masksToBounds = true
        addSubview(cover)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A terminal's frame: the container bounds inflated by the reserved scroller
    /// width so SwiftTerm sizes its columns to the full visible width (the extra
    /// column is clipped by `masksToBounds`). Inflating HERE — rather than in
    /// `ProjectsTerminalView.setFrameSize` — means setting `frame = inflatedFrame` is
    /// idempotent, so re-laying out on every state tick is a no-op instead of
    /// re-triggering a column reflow.
    private var inflatedFrame: NSRect {
        NSRect(x: 0, y: 0,
               width: bounds.width + ProjectsTerminalView.reservedScrollerWidth,
               height: bounds.height)
    }

    /// Only the visible pane (the active terminal, or the cover) needs a current
    /// frame; hidden panes are resized AND fully repainted the instant they're
    /// revealed (see `reveal`), so a window drag never reflows every terminal across
    /// every project, and covered panes burn no draw cycles.
    private func layoutVisible() {
        cover.frame = bounds
        if let id = activeId, let view = hosted[id] { view.frame = inflatedFrame }
    }

    override func layout() {
        super.layout()
        layoutVisible()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutVisible()
    }

    /// Reconcile the hosted terminals against the model's live controllers, bring
    /// `active` to the front, and refresh the empty-state cover.
    /// - Parameters:
    ///   - order: every session id that should be hosted (all live controllers).
    ///   - active: the selected session to show on top, or nil to show the cover.
    ///   - emptyHint: message + button title for the cover when nothing is selected.
    ///   - onNew: backs the cover's button (new session, or new project).
    ///   - provider: supplies the terminal view for a newly-created session.
    func sync(order: [String], active: String?,
              emptyHint: (message: String, button: String),
              onNew: @escaping () -> Void,
              provider: (String) -> ProjectsTerminalView?) {
        let live = Set(order)
        var inserted = Set<String>()
        // Add new sessions AND replace a session whose view INSTANCE changed: when a
        // session's process exits but its dtach master survives, the controller (and
        // its view) is recreated under the SAME id, so keying only on id would keep
        // showing the old, dead view.
        for id in order {
            guard let view = provider(id) else { continue }
            if hosted[id] !== view {
                hosted[id]?.removeFromSuperview()
                view.isHidden = true
                view.frame = inflatedFrame
                addSubview(view)
                hosted[id] = view
                inserted.insert(id)
            }
        }
        for (id, view) in hosted where !live.contains(id) {
            view.removeFromSuperview()
            hosted.removeValue(forKey: id)
        }

        cover.configure(message: emptyHint.message, button: emptyHint.button, onNew: onNew)

        let activeChanged = activeId != active
        activeId = active
        // Show ONLY the active pane (or the cover); hide the rest. Visibility is
        // toggled with isHidden, NOT by reordering the view hierarchy — remove/re-add
        // churned the backing layer, leaving a revealed pane painting only the
        // streaming agent's incremental dirty cells onto a cleared (black) surface
        // (the blank-on-switch glitch). With a stable hierarchy, reveal() forces the
        // one full-bounds repaint a freshly-shown pane needs.
        for (id, view) in hosted { view.isHidden = (id != active) }
        if let active, let view = hosted[active] {
            cover.isHidden = true
            layer?.backgroundColor = view.nativeBackgroundColor.cgColor
            layoutVisible()
            if activeChanged || inserted.contains(active) { reveal(view) }
        } else {
            cover.isHidden = false
            layoutVisible()
        }
        TerminalController.debugLog(
            "container.sync active=\(active?.prefix(8) ?? "nil") changed=\(activeChanged) "
            + "hosted=\(hosted.count) visibleActive=\(active.flatMap { hosted[$0]?.isHidden == false } ?? false)")
    }

    /// Force the just-revealed terminal to the current size and a SYNCHRONOUS,
    /// full-bounds repaint, then focus it. SwiftTerm's draw() paints only the rows
    /// inside the dirtyRect (AppleTerminalView.drawTerminalContents), and a pane that
    /// was hidden accumulates no/partial dirty region — so `display()`, which marks
    /// the whole bounds dirty and draws immediately from SwiftTerm's always-current
    /// model, is what actually fills the surface. `setNeedsDisplay`/`displayIfNeeded`
    /// left it blank.
    private func reveal(_ view: ProjectsTerminalView) {
        view.frame = inflatedFrame
        view.layoutSubtreeIfNeeded()
        view.terminal?.updateFullScreen()
        view.needsDisplay = true
        view.display()
        if let window, window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let id = activeId, let view = hosted[id] else { return }
        reveal(view)
    }
}

/// Centered message + button shown by `TerminalsContainerView` when there is no
/// session to display (no project, or a project with no tabs). Pure AppKit so it
/// reliably composites above the terminal layers — a SwiftUI overlay can render
/// behind a hosted NSView.
private final class EmptyStateView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var onNew: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(tapped)
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(message: String, button title: String, onNew: @escaping () -> Void) {
        label.stringValue = message
        button.title = title
        self.onNew = onNew
    }

    func matchBackground(to color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }

    @objc private func tapped() { onNew?() }
}

/// Hosts the single persistent `TerminalsContainerView` in SwiftUI. The view is
/// created once in `makeNSView`; `updateNSView` only reconciles selection/state, so
/// terminals survive every project and tab switch. `activeSessionId` and `hostedIds`
/// are stored as plain value properties purely so SwiftUI sees the representable
/// change and re-runs `updateNSView` on a tab/project switch.
struct TerminalsContainer: NSViewRepresentable {
    let model: AppModel
    let activeSessionId: String?
    let hostedIds: [String]

    func makeNSView(context: Context) -> TerminalsContainerView {
        TerminalsContainerView(frame: .zero)
    }

    func updateNSView(_ nsView: TerminalsContainerView, context: Context) {
        // Ensure only the ACTIVE session has a controller (cheap, usually already
        // created). The rest of a project's sessions are started eagerly in
        // `selectProject` / `bootstrapIfNeeded` — NOT here — so a SwiftUI layout pass
        // never synchronously forks a batch of dtach processes.
        if let active = activeSessionId { _ = model.controller(for: active) }
        nsView.sync(
            order: model.hostedTerminals.map(\.id),
            active: model.globalSelectedSessionId,
            emptyHint: model.emptyContextHint,
            onNew: { [weak model] in model?.newInActiveContext() },
            provider: { id in model.terminalView(for: id) }
        )
    }
}
