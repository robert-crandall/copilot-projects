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
    }
}

// MARK: - Sidebar (vertical projects)

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedProjectId },
            set: { model.selectProject($0) }
        )) {
            Section("Projects") {
                ForEach(model.projects) { project in
                    ProjectRow(project: project)
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
            }
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
        .navigationTitle("Copilot Mux")
    }
}

struct ProjectRow: View {
    let project: Project

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
            if project.hasUnread {
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
                HSplitView {
                    ForEach(project.sessions) { session in
                        TerminalPane(
                            model: model,
                            projectId: project.id,
                            session: session,
                            isActive: session.id == project.selectedSessionId
                        )
                        .frame(minWidth: 260)
                        .id(session.id)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(project.name).fontWeight(.semibold)
            }
            ToolbarItem {
                Button {
                    model.addSession(toProjectId: project.id)
                } label: {
                    Image(systemName: "plus.rectangle")
                }
                .help("New Session (⌘T)")
            }
        }
    }
}

struct TerminalPane: View {
    @ObservedObject var model: AppModel
    let projectId: String
    let session: Session
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let controller = model.controller(for: session.id) {
                TerminalHostView(terminalView: controller.terminalView, isActive: isActive)
            } else {
                Color.black
            }
        }
        .overlay(
            Rectangle()
                .stroke(isActive ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            StatusDot(status: session.status)
            Text(session.title).font(.caption).lineLimit(1)
            if let text = session.statusText, !text.isEmpty {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.closeSession(projectId: projectId, sessionId: session.id)
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Close Session")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectSession(projectId: projectId, sessionId: session.id)
        }
    }
}
