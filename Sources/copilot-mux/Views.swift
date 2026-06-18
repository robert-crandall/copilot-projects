import SwiftUI
import AppKit
import CopilotMuxCore

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 380)
        } detail: {
            DetailView(model: model)
        }
        .background(WindowConfigurator())
    }
}

/// Hides the window title/chrome so the content fills to the top with only the
/// floating traffic lights, keeping the header minimal.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Sidebar (vertical projects)

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedProjectId },
            set: { model.selectProject($0) }
        )) {
            ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                ProjectRow(
                    project: project,
                    number: index < 9 ? index + 1 : nil,
                    showNumber: model.numberHint == .projects
                )
                    .tag(project.id)
                    .contextMenu {
                        Button("New Session") { model.addSession(toProjectId: project.id) }
                        Button("Rename…") { model.renameProjectInteractive(project.id) }
                        Divider()
                        Button("Close Project", role: .destructive) {
                            model.closeProject(project.id)
                        }
                    }
            }
            .onMove { model.moveProjects(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.addProjectInteractive()
            } label: {
                Label("New Project", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderless)
            .padding(8)
        }
    }
}

struct ProjectRow: View {
    let project: Project
    var number: Int? = nil
    var showNumber: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: project.aggregateStatus)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if showNumber, let number {
                NumberBadge(number: number)
            } else if project.hasUnread {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let count = project.sessions.count
        var parts = ["\(count) session\(count == 1 ? "" : "s")"]
        if project.runningCount > 0 { parts.append("\(project.runningCount) running") }
        if project.waitingCount > 0 { parts.append("\(project.waitingCount) waiting") }
        return parts.joined(separator: " · ")
    }
}

struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
            .help(status.rawValue)
    }

    private var color: Color {
        switch status {
        case .idle: return Color.gray.opacity(0.55)
        case .running: return Color.blue
        case .waiting: return Color.orange
        }
    }
}

/// Keycap-style number shown on projects (⌘) / tabs (⌃) while the modifier is held.
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
        if let project = model.selectedProject {
            ProjectTerminalsView(model: model, project: project)
                .id(project.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("No project selected").font(.title3)
                Button("New Project…") { model.addProjectInteractive() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProjectTerminalsView: View {
    @ObservedObject var model: AppModel
    let project: Project

    var body: some View {
        Group {
            if project.sessions.isEmpty {
                VStack(spacing: 12) {
                    Text("No sessions in “\(project.name)”")
                        .foregroundStyle(.secondary)
                    Button("New Session") { model.addSession(toProjectId: project.id) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    SessionTabBar(model: model, project: project)
                    Divider()
                    terminalArea
                }
            }
        }
    }

    /// All session terminals stay mounted (alive + correctly sized); only the
    /// selected one is visible — browser-tab behavior.
    private var terminalArea: some View {
        let active = project.selectedSessionId ?? project.sessions.first?.id
        return ZStack {
            ForEach(project.sessions) { session in
                if let controller = model.controller(for: session.id) {
                    TerminalHostView(
                        terminalView: controller.terminalView,
                        isActive: session.id == active
                    )
                    .opacity(session.id == active ? 1 : 0)
                    .allowsHitTesting(session.id == active)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SessionTabBar: View {
    @ObservedObject var model: AppModel
    let project: Project

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(project.sessions.enumerated()), id: \.element.id) { index, session in
                    SessionTab(
                        session: session,
                        isActive: session.id == project.selectedSessionId,
                        number: index < 9 ? index + 1 : nil,
                        showNumber: model.numberHint == .tabs,
                        onSelect: { model.selectSession(projectId: project.id, sessionId: session.id) },
                        onClose: { model.requestCloseSession(projectId: project.id, sessionId: session.id) }
                    )
                }
                Button { model.addSession(toProjectId: project.id) } label: {
                    Image(systemName: "plus").font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .help("New Session (⌘T)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct SessionTab: View {
    let session: Session
    let isActive: Bool
    var number: Int? = nil
    var showNumber: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                StatusDot(status: session.status)
                    .opacity(showNumber ? 0 : 1)
                if showNumber, let number {
                    NumberBadge(number: number)
                }
            }
            .frame(width: 18, height: 18)
            Text(session.title)
                .font(.callout)
                .lineLimit(1)
            if session.hasUnread {
                Circle().fill(Color.blue).frame(width: 6, height: 6)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .opacity(0.6)
            .help("Close Session")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 210)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive
                      ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isActive ? Color.accentColor.opacity(0.55) : Color.gray.opacity(0.15),
                        lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help(session.statusText ?? session.title)
    }
}
