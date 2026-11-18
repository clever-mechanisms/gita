import AppKit
import GitaCore

/// Opening a notification's result: the shell shows the window, opens (or selects) the result's repository tab,
/// re-checks that the repository and its provider connection are still the ones the result came from, then shows
/// the result there. A later choice of the user (another tab, another repository) always wins.
extension AppDelegate {
    func openNotification(_ destination: ProviderNotificationDestination) {
        requestAttention(AttentionRequest(destination))
    }

    func requestAttention(_ request: AttentionRequest) {
        // A result explicitly opened while the replacement is waiting takes
        // precedence. Its predecessor gate makes cancellation safe here.
        deferLanguageRestartForNavigation()
        cancelAttentionNavigation()
        attention = .waiting(request)
        guard didFinishLaunching else { return }
        showWindow()
        resumePendingAttention()
    }

    func cancelAttentionNavigation() { attention.cancel() }

    /// Another tab was selected: the tab opened in the background for the result moves it on, any other choice
    /// cancels it (a selection `tabs.open` makes for it while opening is its own).
    func attentionSelectionChanged() {
        switch attention {
        case .idle, .waiting, .opening: break
        case .waitingForTab(let request):
            guard let selected = tabsController?.selectedRepository,
                AttentionRequest.sameLocation(selected, request.repository)
            else {
                cancelAttentionNavigation()
                return
            }
            attention = .routed(request, .init(model: model))
            DispatchQueue.main.async { [weak self] in self?.resumePendingAttention() }
        case .routed, .verifying: cancelAttentionNavigation()
        }
    }

    /// Moves the waiting result on when the shell can take it (called again after each sheet and model change).
    func resumePendingAttention() {
        guard !isLanguageRestarting, didFinishLaunching, let request = attention.pending, attention.isAwaitingShell
        else { return }
        if mainWindow == nil { showWindow() }
        guard let tabsController, tabsController.canChangeRepository, !model.isMutating,
            routeAttention(request, in: tabsController)
        else { return }
        let selectedModel = model
        guard !selectedModel.isLoading else { return }
        guard let snapshot = selectedModel.snapshot, let service = selectedModel.service,
            let controller = repositoryController, AttentionRequest.sameLocation(snapshot.root, request.repository)
        else {
            failAttention(String(localized: "The repository for this result could not be opened."))
            return
        }
        let providers = ProviderService()
        let task = Task { [weak self, weak selectedModel, weak controller] in
            var failure: String?
            do {
                try await request.verify(with: service, providers: providers)
            } catch {
                failure = error.localizedDescription
            }
            self?.finishAttention(
                request, failure: failure, model: selectedModel, controller: controller, service: service)
        }
        attention = .verifying(request, task)
    }

    /// Opens the result's tab, or checks that the tab opened for it is still the selected one. True when the
    /// result's tab is selected now.
    private func routeAttention(_ request: AttentionRequest, in tabs: RepositoryTabsController) -> Bool {
        switch attention {
        case .routed(_, let routed):
            guard model === routed.model, isSelected(request.repository, in: tabs) else {
                cancelAttentionNavigation()
                return false
            }
            return true
        case .waitingForTab:
            // Its tab is switched to once read; a tab closed or dropped meanwhile leaves nothing to wait for.
            if tabs.pendingTab.map({ isResult(request, in: $0) }) != true { cancelAttentionNavigation() }
            return false
        case .idle, .waiting, .opening, .verifying:
            break
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.repository.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            failAttention(String(localized: "The repository for this result is no longer available."))
            return false
        }
        attention = .opening(request)
        guard tabs.open(request.repository) else {
            attention = .waiting(request)
            return false
        }
        // A repository not open yet (or a restored tab not read yet) is read in the background first.
        if let pending = tabs.pendingTab, pending !== tabs.selectedTab, isResult(request, in: pending) {
            attention = .waitingForTab(request)
            return false
        }
        attention = .routed(request, .init(model: model))
        return true
    }

    private func isSelected(_ repository: URL, in tabs: RepositoryTabsController) -> Bool {
        tabs.selectedRepository.map { AttentionRequest.sameLocation($0, repository) } == true
    }

    private func isResult(_ request: AttentionRequest, in tab: RepositoryTabsController.Tab) -> Bool {
        tab.root.map { AttentionRequest.sameLocation($0, request.repository) } == true
    }

    /// The verification ended: shows the result (or the failure) if the same tab, model and repository are still
    /// selected; otherwise the navigation is dropped.
    private func finishAttention(
        _ request: AttentionRequest, failure: String?, model selected: AppModel?, controller: RepositoryViewController?,
        service: GitService
    ) {
        guard !Task.isCancelled, case .verifying(let current, _) = attention, current.id == request.id else { return }
        attention = .routed(request, .init(model: selected))
        let sameController = controller != nil && repositoryController === controller
        guard let selected, model === selected, selected.service === service, failure != nil || sameController else {
            cancelAttentionNavigation()
            return
        }
        guard tabsController?.canChangeRepository == true, !selected.isMutating else { return }
        if let failure {
            failAttention(failure)
            return
        }
        attention = .idle
        controller?.openProviderContext(request.item)
    }

    private func failAttention(_ message: String) {
        cancelAttentionNavigation()
        model.log(String(localized: "Open result failed"), message, failed: true)
        model.showError(String(localized: "Open result"), message)
    }
}
