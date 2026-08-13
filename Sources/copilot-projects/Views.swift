import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CopilotProjectsCore

struct RootView: View {
    @ObservedObject var model: AppModel

    private let titleStripHeight: CGFloat = 38

    var body: some View {
        VStack(spacing: 0) {
            topStrip
            ProjectSwitcherBar(model: model)
                .frame(height: 32)
            Divider()
            HSplitView {
                SessionListView(model: model)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                    .background(SplitViewAutosaver(name: "copilot-projects.sidebar"))
                DetailView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowConfigurator())
    }

    private var topStrip: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            FleetStatusBar(model: model)
                .padding(.trailing, 12)
        }
        .frame(height: titleStripHeight)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

}

/// Removes the title-bar/content separator (a thin line that can pick up the
/// accent color under the strip) and keeps chrome minimal. Retries until the
/// window is attached (it's nil at first).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        func apply(_ attempt: Int) {
            if let window = view.window {
                window.titlebarSeparatorStyle = .none
            } else if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { apply(attempt + 1) }
            }
        }
        DispatchQueue.main.async { apply(0) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Roll-up of what every agent is doing, drawn as a trailing title-bar accessory:
/// the running count (green), background-work sessions (purple), queued schedules
/// (indigo), then the waiting (orange) and ready (blue) counts; "all idle" when
/// nothing is active. (No spinner here — an NSProgressIndicator breaks Auto Layout
/// inside the title-bar accessory's hosting view.)
struct FleetStatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let running = model.totalRunning
        let background = model.totalBackgroundWork
        let scheduled = model.totalScheduled
        let waiting = model.totalWaiting
        let ready = model.totalReady
        HStack(spacing: 10) {
            if running > 0 { Text("\(running) running").foregroundStyle(.green) }
            if background > 0 {
                HStack(spacing: 4) {
                    BackgroundWorkBadge()
                    Text("\(background) background").foregroundStyle(.purple)
                }
            }
            if scheduled > 0 { Text("\(scheduled) scheduled").foregroundStyle(.indigo) }
            if waiting > 0 { Text("\(waiting) waiting").foregroundStyle(.orange) }
            if ready > 0 { Text("\(ready) ready").foregroundStyle(.blue) }
            if running == 0, background == 0, scheduled == 0, waiting == 0, ready == 0 {
                Text("all idle").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .fixedSize()
        .allowsHitTesting(false)
    }
}

/// Gives the HSplitView's underlying NSSplitView an autosave name so it persists
/// its divider position natively (SwiftUI's HSplitView doesn't expose this, and
/// loses the width on relaunch otherwise). Walks up from a background view to
/// find the NSSplitView.
struct SplitViewAutosaver: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            var ancestor = view?.superview
            while let current = ancestor, !(current is NSSplitView) { ancestor = current.superview }
            if let split = ancestor as? NSSplitView, split.autosaveName != name {
                split.autosaveName = name
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ProjectSwitcherBar: View {
    @ObservedObject var model: AppModel
    @State private var dropTargetProjectId: String?

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("All projects") { model.setProjectScope(nil) }
                ForEach(model.projects) { project in
                    Button(project.name) { model.setProjectScope(project.id) }
                }
                Divider()
                Button("New Project…") { model.addProjectInteractive() }
            } label: {
                HStack(spacing: 4) {
                    Text(filterLabel).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.leading, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                        ProjectChip(
                            project: project,
                            isSelected: project.id == model.selectedProjectId,
                            number: index < 9 ? index + 1 : nil,
                            showNumber: model.numberHint == .projects,
                            isDropTarget: dropTargetProjectId == project.id
                        )
                        .onTapGesture { model.selectProject(project.id) }
                        .onDrag {
                            DragPayload.itemProvider(.project, id: project.id)
                        }
                        .onDrop(of: DragPayload.projectDropTypes, delegate: ProjectDropDelegate(
                            projectId: project.id,
                            dropTargetProjectId: $dropTargetProjectId,
                            model: model
                        ))
                        .contextMenu {
                            Button("New Session") { model.addSession(toProjectId: project.id) }
                            Button("Rename…") { model.renameProjectInteractive(project.id) }
                            Divider()
                            Button("Close Project", role: .destructive) {
                                model.closeProject(project.id)
                            }
                        }
                    }
                    Color.clear
                        .frame(width: 18, height: 24)
                        .overlay(alignment: .leading) {
                            InsertionBar().opacity(dropTargetProjectId == "" ? 1 : 0)
                        }
                        .onDrop(of: [DragPayload.projectType], delegate: ProjectDropDelegate(
                            projectId: nil,
                            dropTargetProjectId: $dropTargetProjectId,
                            model: model
                        ))
                }
            }

            Button { model.redrawActiveTerminal() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .hoverHighlight()
            .help("Redraw Terminal")
            .accessibilityLabel("Redraw Terminal")

            Button {
                if let projectId = model.selectedProjectId {
                    model.addSession(toProjectId: projectId)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .hoverHighlight()
            .help("New Session (⌘T)")
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var filterLabel: String {
        guard let id = model.projectScopeId,
              let project = model.projects.first(where: { $0.id == id }) else {
            return "All projects"
        }
        return project.name
    }
}

private struct ProjectChip: View {
    let project: Project
    let isSelected: Bool
    let number: Int?
    let showNumber: Bool
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 5) {
            if project.waitingCount > 0 {
                Circle().fill(.orange).frame(width: 7, height: 7)
            } else if project.runningCount > 0 {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
            Text(project.name).font(.caption).lineLimit(1)
            if showNumber, let number {
                NumberBadge(number: number)
            } else if project.hasUnread {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(.blue)
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                    ? Color.accentColor.opacity(0.18)
                    : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isDropTarget ? Color.accentColor : Color.gray.opacity(0.18),
                    lineWidth: isDropTarget ? 2 : 1
                )
        )
        .contentShape(Rectangle())
    }
}

struct SessionListView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargetId: String?

    var body: some View {
        List(selection: Binding(
            get: { model.globalSelectedSessionId },
            set: { if let id = $0 { model.selectSession(id) } }
        )) {
            ForEach(model.attentionSections) { section in
                Section {
                    if section.entries.isEmpty {
                        Text("No sessions")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(section.entries) { entry in
                            SessionRow(
                                entry: entry,
                                number: number(for: entry.id),
                                showNumber: model.numberHint == .tabs,
                                onClose: {
                                    model.requestCloseSession(
                                        projectId: entry.projectId,
                                        sessionId: entry.id
                                    )
                                }
                            )
                            .tag(entry.id)
                            .onTapGesture { model.selectSession(entry.id) }
                            .overlay(alignment: .top) {
                                InsertionBar(horizontal: true)
                                    .opacity(dropTargetId == entry.id ? 1 : 0)
                            }
                            .onDrag {
                                dropTargetId = nil
                                return DragPayload.itemProvider(
                                    .session,
                                    id: entry.id,
                                    group: section.group
                                )
                            }
                            .onDrop(
                                of: [DragPayload.sessionType(for: section.group)],
                                delegate: SessionListDropDelegate(
                                    targetId: entry.id,
                                    placeAfter: false,
                                    targetGroup: section.group,
                                    dropTargetId: $dropTargetId,
                                    model: model
                                )
                            )
                        }
                        if let last = section.entries.last {
                            Color.clear
                                .frame(height: 12)
                                .overlay(alignment: .top) {
                                    InsertionBar(horizontal: true)
                                        .opacity(dropTargetId == "\(last.id):after" ? 1 : 0)
                                }
                                .onDrop(
                                    of: [DragPayload.sessionType(for: section.group)],
                                    delegate: SessionListDropDelegate(
                                        targetId: last.id,
                                        placeAfter: true,
                                        targetGroup: section.group,
                                        dropTargetId: $dropTargetId,
                                        model: model
                                    )
                                )
                        }
                    }
                } header: {
                    HStack {
                        Text(section.group.title)
                        Spacer()
                        Text("\(section.count)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("v\(CLIMain.versionNumber)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(8)
        }
    }

    private func number(for sessionId: String) -> Int? {
        guard let index = model.visibleSessionOrder.firstIndex(where: { $0.id == sessionId }),
              index < 9 else { return nil }
        return index + 1
    }
}

private struct SessionRow: View {
    let entry: SessionListEntry
    let number: Int?
    let showNumber: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                SessionStatusIndicator(session: entry.session)
                    .opacity(showNumber ? 0 : 1)
                if showNumber, let number { NumberBadge(number: number) }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.session.title)
                    .lineLimit(1)
                    .help(entry.session.statusText ?? entry.session.title)
                Text(entry.projectName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if entry.session.hasBackgroundWork {
                BackgroundWorkBadge()
            } else if !entry.session.schedules.isEmpty {
                ScheduleBadge(schedules: entry.session.schedules)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .opacity(0.6)
            .help("Close Session")
        }
        .contentShape(Rectangle())
    }
}

/// The indicator at the left of a session row. A spinner means the agent is busy
/// (running); orange means it's waiting on your input; blue means it has finished
/// and you haven't viewed it yet ("ready for interaction"); idle shows nothing.
/// The 9pt frame keeps the slot a constant size whether or not a dot is shown.
struct SessionStatusIndicator: View {
    let session: Session

    var body: some View {
        statusIndicator
    }

    private var statusIndicator: some View {
        Group {
            switch kind {
            case .busy:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            case .dot(let color):
                Circle()
                    .fill(color)
                    .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
            case .none:
                Color.clear
            }
        }
        .frame(width: 9, height: 9)
        .help(help)
    }

    private enum Kind { case busy, dot(Color), none }

    private var kind: Kind {
        switch session.status {
        case .running: return .busy
        case .waiting: return .dot(.orange)
        case .idle: return session.finishedUnseen ? .dot(.blue) : .none
        }
    }

    private var help: String {
        switch session.status {
        case .running: return "running"
        case .waiting: return "waiting for input"
        case .idle: return session.finishedUnseen ? "finished — ready for you" : "idle"
        }
    }
}

/// Shown on a session row while background work is active.
/// Sized to the reserved 9pt slot so the project name stays aligned.
struct BackgroundWorkBadge: View {
    var body: some View {
        Image(systemName: "person.2.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 9, height: 9)
            .foregroundStyle(.purple)
            .help("background work active")
    }
}

struct ScheduleBadge: View {
    let schedules: [TrackedSchedule]

    var body: some View {
        Image(systemName: "clock.arrow.circlepath")
            .resizable()
            .scaledToFit()
            .frame(width: 10, height: 10)
            .foregroundStyle(.indigo)
            .help(schedules.map(\.helpText).joined(separator: "\n\n"))
    }
}

/// Keycap-style number shown on projects (⌘) / sessions (⌃) while the modifier is held.
struct NumberBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }
}

// MARK: - Detail (horizontal terminal sessions)

struct DetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // One persistent AppKit container hosts every session's terminal across all
        // projects (see TerminalsContainerView). It's created once and never
        // unmounted, so switching projects or tabs is just a z-order change — SwiftUI
        // never remounts the terminal NSViews, which is what caused the
        // repaint-on-reveal flashes the old opacity/zIndex ZStack couldn't fully fix.
        // Empty / no-project states are drawn by the container's own cover view.
        // activeSessionId + hostedIds are passed so SwiftUI re-runs updateNSView when
        // the selection or the set of sessions changes.
        ZStack(alignment: .trailing) {
            TerminalsContainer(
                model: model,
                activeSessionId: model.globalSelectedSessionId,
                hostedIds: model.hostedTerminals.map(\.id)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let sessionId = model.globalSelectedSessionId,
               let transcript = model.activeTranscriptController {
                TranscriptOverlay(
                    controller: transcript,
                    isOpen: model.isTranscriptDrawerOpen(sessionId: sessionId),
                    onClose: { model.closeTranscriptDrawer(sessionId: sessionId) },
                    onOpen: { model.openTranscriptDrawer(sessionId: sessionId) }
                )
                .id(sessionId)
                .animation(.easeOut(duration: 0.18), value:
                    model.isTranscriptDrawerOpen(sessionId: sessionId))
            }
        }
    }
}

private struct HoverHighlightModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlightModifier())
    }
}

enum DragPayload {
    enum Kind: Equatable {
        case session
        case project
    }

    static func encode(_ kind: Kind, _ id: String) -> String {
        switch kind {
        case .session: return "session:\(id)"
        case .project: return "project:\(id)"
        }
    }

    static func decode(_ raw: String) -> (kind: Kind, id: String)? {
        if raw.hasPrefix("session:") {
            return (.session, String(raw.dropFirst("session:".count)))
        }
        if raw.hasPrefix("project:") {
            return (.project, String(raw.dropFirst("project:".count)))
        }
        return nil
    }

    static let projectType = UTType(
        exportedAs: "com.github.robert-crandall.copilot-projects.drag.project"
    )

    static let projectDropTypes = [projectType] + SessionAttentionGroup.allCases.map(sessionType)

    static func sessionType(for group: SessionAttentionGroup) -> UTType {
        UTType(
            exportedAs: "com.github.robert-crandall.copilot-projects.drag.session.\(group.rawValue)"
        )
    }

    static func itemProvider(
        _ kind: Kind,
        id: String,
        group: SessionAttentionGroup? = nil
    ) -> NSItemProvider {
        let provider = NSItemProvider(object: encode(kind, id) as NSString)
        let type: UTType
        switch kind {
        case .project:
            type = projectType
        case .session:
            guard let group else { return provider }
            type = sessionType(for: group)
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(), nil)
            return nil
        }
        return provider
    }
}

private struct InsertionBar: View {
    var horizontal = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor)
            .frame(
                maxWidth: horizontal ? .infinity : 3,
                maxHeight: horizontal ? 3 : .infinity
            )
    }
}

private struct SessionListDropDelegate: DropDelegate {
    let targetId: String
    let placeAfter: Bool
    let targetGroup: SessionAttentionGroup
    @Binding var dropTargetId: String?
    let model: AppModel

    private var dropKey: String { placeAfter ? "\(targetId):after" : targetId }
    private var acceptedType: UTType { DragPayload.sessionType(for: targetGroup) }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [acceptedType])
    }

    func dropEntered(info: DropInfo) {
        guard info.hasItemsConforming(to: [acceptedType]) else {
            dropTargetId = nil
            return
        }
        dropTargetId = dropKey
    }

    func dropExited(info: DropInfo) {
        if dropTargetId == dropKey { dropTargetId = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        info.hasItemsConforming(to: [acceptedType]) ? DropProposal(operation: .move) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetId = nil
        guard let provider = info.itemProviders(for: [acceptedType]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String,
                  let payload = DragPayload.decode(raw),
                  payload.kind == .session else { return }
            DispatchQueue.main.async {
                model.moveSessionInList(
                    draggedId: payload.id,
                    targetId: targetId,
                    placeAfter: placeAfter
                )
            }
        }
        return true
    }
}

private struct ProjectDropDelegate: DropDelegate {
    let projectId: String?
    @Binding var dropTargetProjectId: String?
    let model: AppModel

    private var dropKey: String { projectId ?? "" }
    private var acceptedTypes: [UTType] {
        projectId == nil ? [DragPayload.projectType] : DragPayload.projectDropTypes
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: acceptedTypes)
    }
    func dropEntered(info: DropInfo) {
        guard info.hasItemsConforming(to: acceptedTypes) else {
            dropTargetProjectId = nil
            return
        }
        dropTargetProjectId = dropKey
    }
    func dropExited(info: DropInfo) {
        if dropTargetProjectId == dropKey { dropTargetProjectId = nil }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        info.hasItemsConforming(to: acceptedTypes)
            ? DropProposal(operation: .move)
            : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetProjectId = nil
        guard let provider = info.itemProviders(for: acceptedTypes).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String,
                  let payload = DragPayload.decode(raw) else { return }
            DispatchQueue.main.async {
                switch payload.kind {
                case .project:
                    model.moveProject(draggedId: payload.id, beforeId: projectId)
                case .session:
                    guard let projectId else { return }
                    model.moveSession(toProjectId: projectId, draggedId: payload.id)
                }
            }
        }
        return true
    }
}
