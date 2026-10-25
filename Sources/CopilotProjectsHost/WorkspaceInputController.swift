import AppKit
import Combine
import CopilotProjectsCore

@MainActor
final class WorkspaceInputController: ObservableObject {
    @Published var imagePreview: TranscriptImagePreviewItem?
    @Published private(set) var sessionFinder: SessionFinderModel?
    @Published private(set) var resumingSessionProjectId: String?
    private let model: AppModel
    private let sessionRanker: SessionRanking
    private let copilotSessionStore: @Sendable () -> CopilotSessionStore
    private let alertPresenter: (NSAlert) -> NSApplication.ModalResponse
    private var resumeSearchTask: Task<Void, Never>?
    private var resumeSearchGeneration: UInt64 = 0

    var isResumingSessionWithPrompt: Bool { resumingSessionProjectId != nil }

    init(
        model: AppModel,
        sessionRanker: SessionRanking = LunaSessionRanker(),
        copilotSessionStore: @escaping @Sendable () -> CopilotSessionStore = { CopilotSessionStore() },
        alertPresenter: @escaping (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    ) {
        self.model = model
        self.sessionRanker = sessionRanker
        self.copilotSessionStore = copilotSessionStore
        self.alertPresenter = alertPresenter
    }

    /// A workspace sheet owns the keyboard, so workspace commands stay disabled.
    var hasWorkspaceSheet: Bool { imagePreview != nil || sessionFinder != nil }

    func presentImage(_ item: TranscriptImagePreviewItem) {
        guard sessionFinder == nil else { return }
        guard model.globalSelectedSessionId == item.id.sessionId,
              model.isTranscriptDrawerOpen(sessionId: item.id.sessionId) else {
            NSLog("Ignoring an image preview from an inactive session drawer.")
            return
        }
        imagePreview = item
    }

    func presentSessionFinder() {
        guard !hasWorkspaceSheet, NSApp.modalWindow == nil else { return }
        model.setNumberHint(.none)
        let projects = model.sessionFinderProjectTargets
        let selectedProjectId = model.selectedProjectId
        let inMemoryCopilotIds = model.inMemoryActiveCopilotSessionIds()
        let initialSessionIds = model.projects.flatMap { $0.sessions.map(\.id) }
        let markerDirectory = model.resumeMarkerDirectory
        let storeProvider = copilotSessionStore
        let defaultStartupDir = Paths.defaultStartupDir
        sessionFinder = SessionFinderModel(
            sources: model.sessionFinderSources,
            currentSessionId: model.globalSelectedSessionId,
            activeCopilotSessionIds: inMemoryCopilotIds,
            ranker: sessionRanker,
            loadResumableEntries: {
                let markerIds = AppModel.validatedMarkerCopilotSessionIds(
                    sessionIds: initialSessionIds, directory: markerDirectory
                )
                return SessionFinderResumableLoader.load(
                    store: storeProvider(),
                    projects: projects,
                    selectedProjectId: selectedProjectId,
                    liveCopilotSessionIds: inMemoryCopilotIds.union(markerIds),
                    defaultStartupDir: defaultStartupDir
                )
            }
        ) { [weak self] sessionId in
            self?.openFromSessionFinder(sessionId)
        }
    }

    func dismissSessionFinder() {
        sessionFinder?.cancel()
        sessionFinder = nil
    }

    func resumeSessionInSelectedProjectInteractive() {
        guard let projectId = model.selectedProjectId else { return }
        resumeSessionInteractive(toProjectId: projectId)
    }

    func resumeSessionInteractive(toProjectId projectId: String, initialPrompt: String = "") {
        guard !isResumingSessionWithPrompt else { return }
        do {
            _ = try model.copilotSessionExecutable(toProjectId: projectId)
        } catch {
            presentResumeErrorAlert(
                title: "Could Not Resume Copilot Session",
                message: error.localizedDescription
            )
            return
        }
        let projectName = model.project(projectId)?.name ?? "Project"
        let composer = CopilotPromptComposer(
            configuration: .resumeSession(projectName: projectName, initialText: initialPrompt)
        )
        _ = composer.run(present: alertPresenter) { prompt in
            _ = self.startResumeSessionSearch(toProjectId: projectId, prompt: prompt)
        }
    }

    @discardableResult
    func startResumeSessionSearch(toProjectId projectId: String, prompt: String) -> Task<Void, Never> {
        resumeSearchTask?.cancel()
        resumeSearchGeneration &+= 1
        let generation = resumeSearchGeneration
        resumingSessionProjectId = projectId
        let task = Task<Void, Never> { [weak self] in
            await self?.performResumeSessionSearch(
                toProjectId: projectId,
                prompt: prompt,
                generation: generation
            )
        }
        resumeSearchTask = task
        return task
    }

    func cancelResumeSessionSearch() {
        resumeSearchTask?.cancel()
        resumeSearchTask = nil
        resumeSearchGeneration &+= 1
        resumingSessionProjectId = nil
    }

    private func clearResumeSearchState(generation: UInt64) {
        guard resumeSearchGeneration == generation else { return }
        resumingSessionProjectId = nil
        resumeSearchTask = nil
    }

    private func performResumeSessionSearch(
        toProjectId projectId: String,
        prompt: String,
        generation: UInt64
    ) async {
        defer { clearResumeSearchState(generation: generation) }
        guard SessionInputValidation.isValidPrompt(prompt) else {
            clearResumeSearchState(generation: generation)
            presentResumeErrorAlert(
                title: "Could Not Resume Copilot Session",
                message: AppModel.CopilotSessionStartError.invalidPrompt.localizedDescription
            )
            return
        }
        do {
            _ = try model.copilotSessionExecutable(toProjectId: projectId)
        } catch {
            clearResumeSearchState(generation: generation)
            presentResumeErrorAlert(
                title: "Could Not Resume Copilot Session",
                message: error.localizedDescription
            )
            return
        }

        let projects = model.sessionFinderProjectTargets
        let inMemoryCopilotIds = model.inMemoryActiveCopilotSessionIds()
        let initialSessionIds = model.projects.flatMap { $0.sessions.map(\.id) }
        let markerDirectory = model.resumeMarkerDirectory
        let storeProvider = copilotSessionStore
        let defaultStartupDir = Paths.defaultStartupDir
        let resumableScan = Task.detached(priority: .userInitiated) {
            let markerIds = AppModel.validatedMarkerCopilotSessionIds(
                sessionIds: initialSessionIds,
                directory: markerDirectory
            )
            let loaded = SessionFinderResumableLoader.load(
                store: storeProvider(),
                projects: projects,
                selectedProjectId: projectId,
                liveCopilotSessionIds: inMemoryCopilotIds.union(markerIds),
                defaultStartupDir: defaultStartupDir,
                limit: SessionFinderResumableLoader.resumePromptLimit
            )
            guard !Task.isCancelled else { return [SessionFinderEntry]() }
            return SessionFinderSearch.prioritizedForRanking(
                query: prompt,
                in: loaded,
                preferredProjectId: projectId
            )
        }
        let loadedEntries = await withTaskCancellationHandler {
            await resumableScan.value
        } onCancel: {
            resumableScan.cancel()
        }
        guard !Task.isCancelled, resumeSearchGeneration == generation else { return }
        guard model.projects.contains(where: { $0.id == projectId }) else {
            clearResumeSearchState(generation: generation)
            presentResumeErrorAlert(
                title: "Could Not Resume Copilot Session",
                message: AppModel.CopilotSessionStartError.projectUnavailable.localizedDescription
            )
            return
        }

        let currentLiveIds = model.inMemoryActiveCopilotSessionIds()
        let availableEntries = loadedEntries.filter { entry in
            guard let copilotId = entry.source.resumableCopilotSessionId?.lowercased() else { return false }
            return !currentLiveIds.contains(copilotId)
        }
        guard !availableEntries.isEmpty else {
            clearResumeSearchState(generation: generation)
            presentResumeErrorAlert(
                title: "No Ended Sessions to Resume",
                message: "No ended Copilot CLI sessions were found in your session history."
            )
            return
        }

        let matches: [LunaMatch]
        do {
            matches = try await sessionRanker.rank(
                query: prompt,
                entries: availableEntries,
                options: .resumePrompt
            )
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  resumeSearchGeneration == generation else { return }
            clearResumeSearchState(generation: generation)
            guard model.projects.contains(where: { $0.id == projectId }) else {
                presentResumeErrorAlert(
                    title: "Could Not Resume Copilot Session",
                    message: AppModel.CopilotSessionStartError.projectUnavailable.localizedDescription
                )
                return
            }
            if presentRecoverableResumeAlert(
                title: "Could Not Find Session",
                message: Self.resumeSearchErrorMessage(for: error)
            ) {
                resumeSessionInteractive(toProjectId: projectId, initialPrompt: prompt)
            }
            return
        }

        guard !Task.isCancelled, resumeSearchGeneration == generation else { return }
        guard let projectName = model.project(projectId)?.name else {
            clearResumeSearchState(generation: generation)
            presentResumeErrorAlert(
                title: "Could Not Resume Copilot Session",
                message: AppModel.CopilotSessionStartError.projectUnavailable.localizedDescription
            )
            return
        }

        let postRankLiveIds = model.inMemoryActiveCopilotSessionIds()
        let entriesById = Dictionary(
            availableEntries.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenIds = Set<String>()
        let candidates: [ResumableSessionCandidate] = matches.compactMap { match in
            guard seenIds.insert(match.sessionId).inserted,
                  let entry = entriesById[match.sessionId],
                  let copilotId = entry.source.resumableCopilotSessionId?.lowercased(),
                  !postRankLiveIds.contains(copilotId) else {
                return nil
            }
            return ResumableSessionCandidate(entry: entry, reason: match.reason)
        }

        clearResumeSearchState(generation: generation)
        dismissSessionFinder()
        imagePreview = nil

        if candidates.isEmpty {
            if presentRecoverableResumeAlert(
                title: "No Matching Session Found",
                message: "No ended Copilot session matched your prompt."
            ) {
                resumeSessionInteractive(toProjectId: projectId, initialPrompt: prompt)
            }
            return
        }

        if candidates.count == 1 {
            completeResumeCandidate(candidates[0], inProjectId: projectId, prompt: prompt)
            return
        }

        let picker = SessionResumeMatchPicker(projectName: projectName, matches: candidates)
        switch picker.run(present: alertPresenter) {
        case .resume(let chosen):
            completeResumeCandidate(chosen, inProjectId: projectId, prompt: prompt)
        case .editPrompt:
            resumeSessionInteractive(toProjectId: projectId, initialPrompt: prompt)
        case .cancelled:
            break
        }
    }

    private func completeResumeCandidate(
        _ candidate: ResumableSessionCandidate,
        inProjectId projectId: String,
        prompt: String
    ) {
        guard let copilotSessionId = candidate.copilotSessionId else { return }
        switch model.resumeEndedSessionInProject(
            copilotSessionId: copilotSessionId,
            projectId: projectId,
            title: candidate.title,
            store: copilotSessionStore()
        ) {
        case .opened(let openedProjectId, let resumedSessionId):
            model.selectSession(projectId: openedProjectId, sessionId: resumedSessionId)
            if model.selectedProjectId != openedProjectId {
                model.selectProject(openedProjectId)
            }
            DispatchQueue.main.async { [model] in model.focusActiveTerminal() }
        case .permanentlyUnavailable(let message), .temporarilyUnavailable(let message):
            guard model.projects.contains(where: { $0.id == projectId }) else {
                presentResumeErrorAlert(
                    title: "Could Not Resume Copilot Session",
                    message: message
                )
                return
            }
            if presentRecoverableResumeAlert(
                title: "Could Not Resume Copilot Session",
                message: message
            ) {
                resumeSessionInteractive(toProjectId: projectId, initialPrompt: prompt)
            }
        }
    }

    static func resumeSearchErrorMessage(for error: Error) -> String {
        guard let lunaError = error as? LunaSearchError else {
            return error.localizedDescription
        }
        switch lunaError {
        case .copilotUnavailable:
            return "The Copilot CLI wasn't found. Install or configure it to search ended sessions."
        case .notSignedIn:
            return "Sign in to the Copilot CLI to search your ended sessions."
        case .timedOut:
            return "The Copilot CLI took too long to search your sessions. Try again or refine your prompt."
        case .failed(let detail):
            return "The Copilot CLI couldn't search your sessions: \(detail)"
        case .unreadableResponse:
            return "The Copilot CLI returned an unreadable search response. Try again."
        }
    }

    private func presentResumeErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = alertPresenter(alert)
    }

    /// Presents an alert with "Edit Prompt…" and "Cancel"; returns `true` when the
    /// user chooses "Edit Prompt…".
    private func presentRecoverableResumeAlert(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Edit Prompt…")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        return alertPresenter(alert) == .alertFirstButtonReturn
    }

    func openFromSessionFinder(_ sessionId: String) {
        // Select a live session directly when it is open in the workspace.
        if let project = model.projects.first(where: { project in
            project.sessions.contains { $0.id == sessionId }
        }) {
            dismissSessionFinder()
            // Select the session first: switching projects marks the project's
            // selected tab as seen, and that should be the tab being opened.
            model.selectSession(projectId: project.id, sessionId: sessionId)
            if model.selectedProjectId != project.id { model.selectProject(project.id) }
            DispatchQueue.main.async { [model] in model.focusActiveTerminal() }
            return
        }
        // Resume an ended Copilot CLI session into its matched project.
        guard let source = sessionFinder?.source(for: sessionId),
              let copilotSessionId = source.resumableCopilotSessionId else {
            return
        }
        switch model.resumeFromSessionFinder(
            copilotSessionId: copilotSessionId,
            preferredProjectId: source.projectId,
            cwd: source.cwd,
            repository: source.repository,
            title: source.title,
            store: copilotSessionStore()
        ) {
        case .opened(let projectId, let resumedSessionId):
            dismissSessionFinder()
            model.selectSession(projectId: projectId, sessionId: resumedSessionId)
            if model.selectedProjectId != projectId { model.selectProject(projectId) }
            DispatchQueue.main.async { [model] in model.focusActiveTerminal() }
        case .permanentlyUnavailable(let message):
            sessionFinder?.removeResumableSession(id: sessionId, error: message)
        case .temporarilyUnavailable(let message):
            sessionFinder?.setResumeError(message)
        }
    }

    func allowsWorkspaceEvents(_ event: NSEvent) -> Bool {
        imagePreview == nil && NSApp.modalWindow == nil
            && event.window?.sheetParent == nil && event.window?.attachedSheet == nil
            && NSApp.keyWindow?.sheetParent == nil && NSApp.keyWindow?.attachedSheet == nil
    }

    func handleOtherMouse(_ event: NSEvent) -> NSEvent? {
        guard !hasWorkspaceSheet, allowsWorkspaceEvents(event) else { return event }
        switch event.buttonNumber {
        case 3:
            if event.type == .otherMouseDown {
                model.navigateSessionBack()
            }
            return nil
        case 4:
            if event.type == .otherMouseDown {
                model.navigateSessionForward()
            }
            return nil
        default:
            return event
        }
    }

    func handleKeyDown(_ event: NSEvent, cancelNumberHint: () -> Void = {}) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        func clearNumberHint() {
            cancelNumberHint()
            model.setNumberHint(.none)
        }
        guard NSApp.modalWindow == nil else {
            clearNumberHint()
            return event
        }
        if let finder = sessionFinder {
            clearNumberHint()
            return handleSessionFinderKey(event, finder: finder, mods: mods)
        }
        if imagePreview != nil {
            clearNumberHint()
            if (mods == .command && event.charactersIgnoringModifiers == "w")
                || (mods.isEmpty && event.keyCode == 53) {
                imagePreview = nil
                return nil
            }
            // Native preview controls keep their own keyboard handling. Events
            // aimed at the underlying workspace must not reach its terminal.
            return event.window?.sheetParent == nil ? nil : event
        }
        guard allowsWorkspaceEvents(event) else {
            clearNumberHint()
            return event
        }
        if mods == .command, event.charactersIgnoringModifiers == "w" {
            model.closeSelectedSession()
            return nil
        }
        if mods == .command, event.charactersIgnoringModifiers == "k" {
            clearNumberHint()
            presentSessionFinder()
            return nil
        }
        if mods == .command, event.charactersIgnoringModifiers == "[" {
            clearNumberHint()
            model.navigateSessionBack()
            return nil
        }
        if mods == .command, event.charactersIgnoringModifiers == "]" {
            clearNumberHint()
            model.navigateSessionForward()
            return nil
        }
        if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "a" {
            clearNumberHint()
            model.selectNextAttentionSession()
            return nil
        }
        if event.keyCode == 48 {
            if mods == .control { model.selectAdjacentSession(1); return nil }
            if mods == [.control, .shift] { model.selectAdjacentSession(-1); return nil }
        }
        if let value = event.charactersIgnoringModifiers, value.count == 1,
           let digit = Int(value), (1...9).contains(digit) {
            if mods == .command {
                clearNumberHint()
                model.selectProjectByIndex(digit - 1)
                return nil
            }
            if mods == .control {
                clearNumberHint()
                model.selectSessionByIndex(digit - 1)
                return nil
            }
        }
        clearNumberHint()
        if let controller = model.activeController,
           controller.terminalView.sendRestoredModifiedReturnIfNeeded(
               for: event,
               restoredAgentLive: controller.reattachedToExistingShell
                   && model.liveAgentSessions.contains(controller.sessionId),
               copilotFooterVisible: controller.showsCopilotFooter
           ) {
            return nil
        }
        return event
    }

    /// Navigation keys drive the finder's list while its search field keeps
    /// focus. Keys an input method is composing are left to the field.
    private func handleSessionFinderKey(
        _ event: NSEvent, finder: SessionFinderModel, mods: NSEvent.ModifierFlags
    ) -> NSEvent? {
        let key = event.charactersIgnoringModifiers
        if mods == .command, key == "w" || key == "k" {
            if key == "w" { dismissSessionFinder() }
            return nil
        }
        let composing = (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true
        if !composing {
            switch event.keyCode {
            case 53 where mods.isEmpty:
                // Like Spotlight, Escape clears a search before it closes.
                if finder.query.isEmpty {
                    dismissSessionFinder()
                } else {
                    finder.query = ""
                }
                return nil
            case 125 where mods.isEmpty:
                finder.moveHighlight(1)
                return nil
            case 126 where mods.isEmpty:
                finder.moveHighlight(-1)
                return nil
            case 36 where mods.isEmpty, 76 where mods.isEmpty:
                finder.openHighlighted()
                return nil
            default:
                break
            }
            if mods == .control, key == "n" || key == "p" {
                finder.moveHighlight(key == "n" ? 1 : -1)
                return nil
            }
        }
        // Events aimed at the underlying workspace must not reach its terminal.
        return event.window?.sheetParent == nil ? nil : event
    }
}
