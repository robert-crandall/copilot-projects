import SwiftUI
import AppKit
import CopilotMuxCore

/// Single source of truth. Holds value-type projects/sessions (observed) and live
/// terminal controllers (NOT observed, kept out of the SwiftUI graph).
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var selectedProjectId: String?

    private var controllers: [String: TerminalController] = [:]
    private var server: ControlServer?
    private weak var notifications: NotificationManager?
    private var saveWork: DispatchWorkItem?

    init() {
        load()
    }

    // MARK: - lifecycle wiring

    func attach(notifications: NotificationManager) {
        self.notifications = notifications
    }

    func bootstrapIfNeeded() {
        if projects.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let project = makeProject(name: "home", cwd: home, withSession: true)
            projects.append(project)
            selectedProjectId = project.id
            save()
        } else if selectedProjectId == nil {
            selectedProjectId = projects.first?.id
        }
        if let sid = currentSelectedSessionId { _ = controller(for: sid) }
    }

    func startServer() {
        let server = ControlServer { [weak self] req in
            guard let self else { return .failure("app shutting down") }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated { self.handle(req) }
            }
        }
        server.start()
        self.server = server
    }

    func stopServer() {
        server?.stop()
    }

    /// Best-effort: symlink the bundled binary onto the user's PATH so terminal
    /// hooks can call `copilot-mux`.
    func installCLISymlinkIfPossible() {
        guard let exe = Bundle.main.executablePath else { return }
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        let link = dir.appendingPathComponent("copilot-mux")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path), dest == exe { return }
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: exe)
    }

    // MARK: - derived

    var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return projects.first { $0.id == id }
    }

    func project(_ id: String) -> Project? {
        projects.first { $0.id == id }
    }

    private var currentSelectedSessionId: String? {
        guard let pid = selectedProjectId, let pi = projectIndex(pid) else { return nil }
        return projects[pi].selectedSessionId
    }

    // MARK: - terminal controllers (lazy, cached, not observed)

    /// Returns (creating if needed) the live terminal for a session.
    @discardableResult
    func controller(for sessionId: String) -> TerminalController? {
        if let c = controllers[sessionId] { return c }
        guard let loc = locateIndex(sessionId) else { return nil }
        let project = projects[loc.p]
        let session = project.sessions[loc.s]
        let c = TerminalController(
            sessionId: sessionId,
            cwd: session.cwd,
            extraEnvironment: environment(projectId: project.id, sessionId: sessionId)
        )
        c.onTitle = { [weak self] title in self?.updateTitle(sessionId: sessionId, title: title) }
        c.onDirectory = { [weak self] dir in self?.updateCwd(sessionId: sessionId, dir: dir) }
        c.onExit = { [weak self] _ in self?.handleExit(sessionId: sessionId) }
        controllers[sessionId] = c
        return c
    }

    private func environment(projectId: String, sessionId: String) -> [String: String] {
        [
            "COPILOT_MUX": "1",
            "COPILOT_MUX_SOCKET": Paths.socketPath,
            "COPILOT_MUX_PROJECT": projectId,
            "COPILOT_MUX_SESSION": sessionId,
        ]
    }

    // MARK: - project / session mutations

    private func makeProject(name: String, cwd: String, withSession: Bool) -> Project {
        var project = Project(name: name, cwd: cwd)
        if withSession {
            let session = Session(title: "shell", cwd: cwd)
            project.sessions = [session]
            project.selectedSessionId = session.id
        }
        return project
    }

    /// Choose a folder, then create a project rooted there.
    func addProjectInteractive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose a folder for the new project"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = makeProject(name: url.lastPathComponent, cwd: url.path, withSession: true)
        projects.append(project)
        selectProject(project.id)
    }

    @discardableResult
    func addSession(toProjectId pid: String, cwd: String? = nil) -> String? {
        guard let pi = projectIndex(pid) else { return nil }
        let dir = cwd ?? projects[pi].cwd
        let session = Session(title: "shell", cwd: dir)
        projects[pi].sessions.append(session)
        projects[pi].selectedSessionId = session.id
        controller(for: session.id)
        save()
        return session.id
    }

    func addSessionToSelected() {
        guard let pid = selectedProjectId else { return }
        addSession(toProjectId: pid)
    }

    func closeSession(projectId pid: String, sessionId sid: String) {
        guard let pi = projectIndex(pid) else { return }
        controllers[sid]?.terminate()
        controllers[sid] = nil
        projects[pi].sessions.removeAll { $0.id == sid }
        if projects[pi].selectedSessionId == sid {
            projects[pi].selectedSessionId = projects[pi].sessions.first?.id
        }
        updateDockBadge()
        save()
    }

    func closeSelectedSession() {
        guard let pid = selectedProjectId, let pi = projectIndex(pid),
              let sid = projects[pi].selectedSessionId else { return }
        closeSession(projectId: pid, sessionId: sid)
    }

    func closeProject(_ pid: String) {
        guard let pi = projectIndex(pid) else { return }
        for session in projects[pi].sessions {
            controllers[session.id]?.terminate()
            controllers[session.id] = nil
        }
        projects.remove(at: pi)
        if selectedProjectId == pid {
            selectedProjectId = projects.first?.id
            if let sid = currentSelectedSessionId { controller(for: sid) }
        }
        updateDockBadge()
        save()
    }

    func renameProject(_ pid: String, name: String) {
        guard let pi = projectIndex(pid) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projects[pi].name = trimmed
        save()
    }

    func renameProjectInteractive(_ pid: String) {
        guard let pi = projectIndex(pid) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Project"
        alert.informativeText = "Enter a new name for this project."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = projects[pi].name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            renameProject(pid, name: field.stringValue)
        }
    }

    func selectProject(_ id: String?) {
        selectedProjectId = id
        if let id, let pi = projectIndex(id) {
            for i in projects[pi].sessions.indices {
                projects[pi].sessions[i].hasUnread = false
            }
            for session in projects[pi].sessions {
                controller(for: session.id)
            }
        }
        updateDockBadge()
        save()
    }

    func selectSession(projectId pid: String, sessionId sid: String) {
        guard let pi = projectIndex(pid) else { return }
        if let si = projects[pi].sessions.firstIndex(where: { $0.id == sid }) {
            projects[pi].sessions[si].hasUnread = false
        }
        projects[pi].selectedSessionId = sid
        controller(for: sid)
        updateDockBadge()
        save()
    }

    // MARK: - status / notifications (driven by the CLI)

    func setStatus(sessionId: String, status: SessionStatus, text: String?) {
        guard let loc = locateIndex(sessionId) else { return }
        projects[loc.p].sessions[loc.s].status = status
        projects[loc.p].sessions[loc.s].statusText = text
    }

    func postNotification(projectId: String, sessionId: String, title: String, body: String?) {
        if let loc = locateIndex(sessionId) {
            let visible = NSApp.isActive
                && selectedProjectId == projectId
                && projects[loc.p].selectedSessionId == sessionId
            if !visible {
                projects[loc.p].sessions[loc.s].hasUnread = true
            }
        }
        notifications?.post(title: title, body: body, projectId: projectId, sessionId: sessionId)
        updateDockBadge()
    }

    func focus(projectId: String?, sessionId: String?) {
        NSApp.activate(ignoringOtherApps: true)
        if let sessionId, let loc = locateIndex(sessionId) {
            selectedProjectId = projects[loc.p].id
            projects[loc.p].selectedSessionId = sessionId
            projects[loc.p].sessions[loc.s].hasUnread = false
        } else if let projectId, let pi = projectIndex(projectId) {
            selectedProjectId = projectId
            for i in projects[pi].sessions.indices {
                projects[pi].sessions[i].hasUnread = false
            }
        }
        if let sid = currentSelectedSessionId { controller(for: sid) }
        updateDockBadge()
    }

    private func updateDockBadge() {
        let count = projects.reduce(0) { acc, p in
            acc + p.sessions.filter { $0.hasUnread }.count
        }
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: - terminal callbacks

    private func updateTitle(sessionId: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let loc = locateIndex(sessionId) else { return }
        if projects[loc.p].sessions[loc.s].title != trimmed {
            projects[loc.p].sessions[loc.s].title = trimmed
            scheduleSave()
        }
    }

    private func updateCwd(sessionId: String, dir: String?) {
        guard let dir, !dir.isEmpty, let loc = locateIndex(sessionId) else { return }
        if projects[loc.p].sessions[loc.s].cwd != dir {
            projects[loc.p].sessions[loc.s].cwd = dir
            scheduleSave()
        }
    }

    private func handleExit(sessionId: String) {
        controllers[sessionId] = nil
        guard let loc = locateIndex(sessionId) else { return }
        let pid = projects[loc.p].id
        closeSession(projectId: pid, sessionId: sessionId)
    }

    // MARK: - control socket handler

    func handle(_ req: ControlRequest) -> ControlResponse {
        switch req.command {
        case "ping":
            return .success("pong")
        case "list-projects":
            return .success(renderProjects())
        case "list-status":
            return .success(renderStatus())
        case "set-status":
            guard let raw = req.status,
                  let status = SessionStatus(rawValue: raw.lowercased()) else {
                return .failure("invalid status (use idle|running|waiting): \(req.status ?? "")")
            }
            guard let target = resolve(req) else { return .failure("no target session") }
            setStatus(sessionId: target.sessionId, status: status, text: req.text)
            return .success()
        case "notify":
            guard let title = req.title else { return .failure("notify requires a title") }
            if let target = resolve(req) {
                postNotification(projectId: target.projectId, sessionId: target.sessionId,
                                 title: title, body: req.body)
            } else {
                // No session context: still surface a banner, just without unread/focus routing.
                notifications?.post(title: title, body: req.body,
                                    projectId: req.projectId, sessionId: req.sessionId)
            }
            return .success()
        case "new-project":
            let cwd = req.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            let name = req.name ?? URL(fileURLWithPath: cwd).lastPathComponent
            let project = makeProject(name: name, cwd: cwd, withSession: true)
            projects.append(project)
            selectProject(project.id)
            return .success(project.id)
        case "new-session":
            guard let pid = req.projectId ?? selectedProjectId else { return .failure("no project") }
            guard let sid = addSession(toProjectId: pid, cwd: req.cwd) else {
                return .failure("unknown project: \(pid)")
            }
            return .success(sid)
        case "rename-project":
            guard let pid = req.projectId ?? selectedProjectId else { return .failure("no project") }
            guard let name = req.name else { return .failure("rename-project requires a name") }
            renameProject(pid, name: name)
            return .success()
        case "focus":
            focus(projectId: req.projectId, sessionId: req.sessionId)
            return .success()
        default:
            return .failure("unknown command: \(req.command)")
        }
    }

    private func resolve(_ req: ControlRequest) -> (projectId: String, sessionId: String)? {
        if let sid = req.sessionId, let loc = locateIndex(sid) {
            return (projects[loc.p].id, sid)
        }
        if let pid = req.projectId, let pi = projectIndex(pid) {
            if let sid = projects[pi].selectedSessionId ?? projects[pi].sessions.first?.id {
                return (pid, sid)
            }
        }
        return nil
    }

    private func renderProjects() -> String {
        if projects.isEmpty { return "(no projects)" }
        return projects.map { p in
            let marker = p.id == selectedProjectId ? "*" : " "
            let counts = "\(p.sessions.count) session\(p.sessions.count == 1 ? "" : "s")"
            return "\(marker) [\(p.aggregateStatus.rawValue)] \(p.name)  (\(counts))  \(p.id)"
        }.joined(separator: "\n")
    }

    private func renderStatus() -> String {
        var lines: [String] = []
        for p in projects {
            for s in p.sessions {
                let extra = s.statusText.map { " — \($0)" } ?? ""
                let unread = s.hasUnread ? " [unread]" : ""
                lines.append("\(p.name)/\(s.title)  \(s.status.rawValue)\(unread)\(extra)  \(s.id)")
            }
        }
        return lines.isEmpty ? "(no sessions)" : lines.joined(separator: "\n")
    }

    // MARK: - indexing

    private func projectIndex(_ id: String) -> Int? {
        projects.firstIndex { $0.id == id }
    }

    private func locateIndex(_ sessionId: String) -> (p: Int, s: Int)? {
        for (pi, p) in projects.enumerated() {
            if let si = p.sessions.firstIndex(where: { $0.id == sessionId }) {
                return (pi, si)
            }
        }
        return nil
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.statePath),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        projects = state.projects
        selectedProjectId = state.selectedProjectId ?? state.projects.first?.id
        for pi in projects.indices {
            for si in projects[pi].sessions.indices {
                projects[pi].sessions[si].status = .idle
                projects[pi].sessions[si].statusText = nil
                projects[pi].sessions[si].hasUnread = false
            }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func save() {
        Paths.ensureStateDir()
        let state = PersistedState(projects: projects, selectedProjectId: selectedProjectId)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Paths.statePath, options: .atomic)
    }
}
