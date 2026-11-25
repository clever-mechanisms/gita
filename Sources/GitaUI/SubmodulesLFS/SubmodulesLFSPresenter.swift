import AppKit
import GitaCore

/// Tab selection for the Submodules & Git LFS management window.
enum SubmodulesLFSTab: Int, CaseIterable, Sendable {
    case submodules
    case lfs

    var title: String {
        switch self {
        case .submodules:
            return String(localized: "Submodules")
        case .lfs:
            return String(localized: "Git LFS")
        }
    }

    var symbolName: String {
        switch self {
        case .submodules:
            return "shippingbox"
        case .lfs:
            return "externaldrive.badge.checkmark"
        }
    }
}

/// Injectable backend actions so tests can drive every lifecycle transition without a real Git process.
struct SubmodulesLFSActions: Sendable {
    var loadSubmodules: @Sendable () async throws -> [GitSubmodule]
    var initSubmodules: @Sendable (_ path: String?, _ recursive: Bool) async throws -> Void
    var updateSubmodules: @Sendable (_ path: String?, _ recursive: Bool) async throws -> Void
    var syncSubmodules: @Sendable (_ path: String?, _ recursive: Bool) async throws -> Void
    var loadLFS: @Sendable () async throws -> LFSStatus
    var lockLFS: @Sendable (_ path: String) async throws -> Void
    var unlockLFS: @Sendable (_ path: String, _ force: Bool) async throws -> Void

    static func live(service: GitService) -> Self {
        Self(
            loadSubmodules: { try await service.submodules() },
            initSubmodules: { path, recursive in
                try await service.initializeSubmodules(path: path, recursive: recursive)
            },
            updateSubmodules: { path, recursive in
                try await service.updateSubmodules(path: path, recursive: recursive)
            },
            syncSubmodules: { path, recursive in
                try await service.syncSubmodules(path: path, recursive: recursive)
            },
            loadLFS: { try await service.lfsStatus(includeLocks: true) },
            lockLFS: { path in try await service.lfsLock(path: path) },
            unlockLFS: { path, force in try await service.lfsUnlock(path: path, force: force) }
        )
    }
}

private enum SubmoduleLifecycle {
    case idle
    case loading(Task<Void, Never>)
    case loaded([GitSubmodule], error: String? = nil)
    case mutating(action: String, submodules: [GitSubmodule], task: Task<Void, Never>)
    case failed(String)

    var publicState: SubmoduleLoadState {
        switch self {
        case .idle:
            return .idle
        case .loading:
            return .loading
        case .loaded(let items, let error):
            return .loaded(items, error: error)
        case .mutating(let action, let items, _):
            return .mutating(action: action, submodules: items)
        case .failed(let message):
            return .failed(message)
        }
    }

    func cancelReadTask() {
        if case .loading(let task) = self {
            task.cancel()
        }
    }
}

private enum LFSLifecycle {
    case idle
    case loading(Task<Void, Never>)
    case loaded(LFSStatus, error: String? = nil)
    case mutating(action: String, status: LFSStatus, task: Task<Void, Never>)
    case failed(String)

    var publicState: LFSLoadState {
        switch self {
        case .idle:
            return .idle
        case .loading:
            return .loading
        case .loaded(let status, let error):
            return .loaded(status, error: error)
        case .mutating(let action, let status, _):
            return .mutating(action: action, status: status)
        case .failed(let message):
            return .failed(message)
        }
    }

    func cancelReadTask() {
        if case .loading(let task) = self {
            task.cancel()
        }
    }
}

/// Presentation state and explicit action coordinator for the Submodules & Git LFS management window.
/// Holds each tab's lifecycle in a single enum carrying its in-flight task, with zero background polling.
@MainActor
final class SubmodulesLFSPresenter {
    typealias Tab = SubmodulesLFSTab
    typealias Actions = SubmodulesLFSActions

    let repositoryRoot: URL
    private let actions: Actions
    private var submoduleLifecycle: SubmoduleLifecycle = .idle
    private var lfsLifecycle: LFSLifecycle = .idle

    private(set) var selectedTab: Tab = .submodules
    var selectedSubmodulePath: String? {
        didSet { if selectedSubmodulePath != oldValue { onChange?() } }
    }
    var selectedLFSFilePath: String? {
        didSet { if selectedLFSFilePath != oldValue { onChange?() } }
    }

    var onChange: (() -> Void)?
    var onOpenInTab: ((URL) -> Void)?
    var onRevealInFinder: ((URL) -> Void)?

    init(repositoryRoot: URL, actions: Actions) {
        self.repositoryRoot = repositoryRoot.standardizedFileURL
        self.actions = actions
    }

    convenience init(repositoryRoot: URL, service: GitService) {
        self.init(repositoryRoot: repositoryRoot, actions: .live(service: service))
    }

    isolated deinit {
        submoduleLifecycle.cancelReadTask()
        lfsLifecycle.cancelReadTask()
    }

    var submoduleState: SubmoduleLoadState { submoduleLifecycle.publicState }
    var lfsState: LFSLoadState { lfsLifecycle.publicState }
    var repositoryName: String { repositoryRoot.lastPathComponent }

    var selectedSubmodule: GitSubmodule? {
        guard let selectedSubmodulePath else { return nil }
        return submoduleState.submodules.first { $0.path == selectedSubmodulePath }
    }

    var selectedLFSFile: LFSFileEntry? {
        guard let selectedLFSFilePath, let status = lfsState.status else { return nil }
        return status.files.first { $0.path == selectedLFSFilePath }
    }

    var selectedLFSLock: LFSLockEntry? {
        guard let selectedLFSFilePath, let status = lfsState.status else { return nil }
        return status.lock(forPath: selectedLFSFilePath)
    }

    var submoduleTabBadge: String? {
        let count = submoduleState.submodules.count
        return count > 0 ? "\(count)" : nil
    }

    var lfsTabBadge: String? {
        guard let status = lfsState.status else { return nil }
        let count = status.files.count
        return count > 0 ? "\(count)" : nil
    }

    var canOpenSelectedSubmodule: Bool {
        guard let selectedSubmodule else { return false }
        return selectedSubmodule.status != .uninitialized
    }

    var isActiveTabBusy: Bool {
        switch selectedTab {
        case .submodules:
            return submoduleState.isBusy
        case .lfs:
            return lfsState.isBusy
        }
    }

    static func formattedCacheSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    func selectTab(_ tab: Tab) {
        guard selectedTab != tab else { return }
        selectedTab = tab
        onChange?()
        if tab == .submodules, case .idle = submoduleLifecycle {
            loadSubmodules()
        } else if tab == .lfs, case .idle = lfsLifecycle {
            loadLFS()
        }
    }

    func refreshActiveTab() {
        switch selectedTab {
        case .submodules:
            loadSubmodules()
        case .lfs:
            loadLFS()
        }
    }

    func loadSubmodules() {
        guard !submoduleState.isMutating else { return }
        submoduleLifecycle.cancelReadTask()
        let load = actions.loadSubmodules
        let task = Task { @MainActor [weak self] in
            do {
                let items = try await load()
                guard let self, !Task.isCancelled else { return }
                self.reconcileSubmoduleSelection(items)
                self.setSubmoduleLifecycle(.loaded(items))
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setSubmoduleLifecycle(.failed(error.localizedDescription))
            }
        }
        setSubmoduleLifecycle(.loading(task))
    }

    func initializeSubmodules(path: String? = nil, recursive: Bool = false) {
        let title =
            path.map { String(localized: "Initializing \($0)…") }
            ?? String(localized: "Initializing submodules…")
        let operation = actions.initSubmodules
        runSubmoduleMutation(title: title) { try await operation(path, recursive) }
    }

    func updateSubmodules(path: String? = nil, recursive: Bool = false) {
        let title =
            path.map { String(localized: "Updating \($0)…") }
            ?? String(localized: "Updating submodules…")
        let operation = actions.updateSubmodules
        runSubmoduleMutation(title: title) { try await operation(path, recursive) }
    }

    func syncSubmodules(path: String? = nil, recursive: Bool = false) {
        let title =
            path.map { String(localized: "Syncing \($0)…") }
            ?? String(localized: "Syncing submodules…")
        let operation = actions.syncSubmodules
        runSubmoduleMutation(title: title) { try await operation(path, recursive) }
    }

    func loadLFS() {
        guard !lfsState.isMutating else { return }
        lfsLifecycle.cancelReadTask()
        let load = actions.loadLFS
        let task = Task { @MainActor [weak self] in
            do {
                let status = try await load()
                guard let self, !Task.isCancelled else { return }
                self.reconcileLFSSelection(status)
                self.setLFSLifecycle(.loaded(status))
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setLFSLifecycle(.failed(error.localizedDescription))
            }
        }
        setLFSLifecycle(.loading(task))
    }

    func lockLFSFile(path: String) {
        let operation = actions.lockLFS
        runLFSMutation(title: String(localized: "Locking \(path)…")) { try await operation(path) }
    }

    func unlockLFSFile(path: String, force: Bool = false) {
        let operation = actions.unlockLFS
        runLFSMutation(title: String(localized: "Unlocking \(path)…")) { try await operation(path, force) }
    }

    func openSubmoduleInTab(_ submodule: GitSubmodule) {
        guard submodule.status != .uninitialized else { return }
        onOpenInTab?(submodule.resolvedURL(in: repositoryRoot))
    }

    func revealSubmoduleInFinder(_ submodule: GitSubmodule) {
        onRevealInFinder?(submodule.resolvedURL(in: repositoryRoot))
    }

    func revealLFSFileInFinder(_ file: LFSFileEntry) {
        onRevealInFinder?(repositoryRoot.appendingPathComponent(file.path).standardizedFileURL)
    }

    /// Cancels only read/load tasks when closing the window; never aborts in-flight Git mutations.
    func cancelReads() {
        submoduleLifecycle.cancelReadTask()
        lfsLifecycle.cancelReadTask()
        if case .loading = submoduleLifecycle {
            setSubmoduleLifecycle(.idle)
        }
        if case .loading = lfsLifecycle {
            setLFSLifecycle(.idle)
        }
    }

    private func runSubmoduleMutation(title: String, operation: @escaping @Sendable () async throws -> Void) {
        guard !submoduleState.isBusy else { return }
        let current = submoduleState.submodules
        let reload = actions.loadSubmodules
        let task = Task { @MainActor [weak self] in
            do {
                try await operation()
                let updated = try await reload()
                guard let self else { return }
                self.reconcileSubmoduleSelection(updated)
                self.setSubmoduleLifecycle(.loaded(updated))
            } catch {
                guard let self else { return }
                self.setSubmoduleLifecycle(.loaded(current, error: error.localizedDescription))
            }
        }
        setSubmoduleLifecycle(.mutating(action: title, submodules: current, task: task))
    }

    private func runLFSMutation(title: String, operation: @escaping @Sendable () async throws -> Void) {
        guard !lfsState.isBusy, let current = lfsState.status else { return }
        let reload = actions.loadLFS
        let task = Task { @MainActor [weak self] in
            do {
                try await operation()
                let updated = try await reload()
                guard let self else { return }
                self.reconcileLFSSelection(updated)
                self.setLFSLifecycle(.loaded(updated))
            } catch {
                guard let self else { return }
                self.setLFSLifecycle(.loaded(current, error: error.localizedDescription))
            }
        }
        setLFSLifecycle(.mutating(action: title, status: current, task: task))
    }

    private func reconcileSubmoduleSelection(_ items: [GitSubmodule]) {
        if let selected = selectedSubmodulePath, !items.contains(where: { $0.path == selected }) {
            selectedSubmodulePath = nil
        }
    }

    private func reconcileLFSSelection(_ status: LFSStatus) {
        if let selected = selectedLFSFilePath, !status.files.contains(where: { $0.path == selected }) {
            selectedLFSFilePath = nil
        }
    }

    private func setSubmoduleLifecycle(_ next: SubmoduleLifecycle) {
        submoduleLifecycle = next
        onChange?()
    }

    private func setLFSLifecycle(_ next: LFSLifecycle) {
        lfsLifecycle = next
        onChange?()
    }
}
