import Foundation
import GitaCore

@MainActor
final class WorkspaceCommandCenterPresenter {
    enum Tab: Int { case changes, lockstep, timeline }
    enum Filter: Int { case all, commits, pullRequests, deployments }

    private(set) var repositories: [WorkspaceRepository]
    private var reports: [URL: [ProviderReport]]
    private let defaults: UserDefaults
    private static let tabKey = "controlPlane.workspace.lastTab"
    private(set) var open: @MainActor (URL) -> Void
    var changed: (() -> Void)?
    private(set) var tab: Tab
    private(set) var selected: Set<String>
    private(set) var filter = Filter.all
    private(set) var changes = WorkspaceChangesState.idle
    private(set) var lockstep = LockstepBranchState.idle
    private(set) var timeline = WorkspaceTimelineState.idle
    private(set) var branchName = ""
    private(set) var mode = LockstepBranchMode.createOrCheckout
    private var changesTask: Task<Void, Never>?
    private var branchTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?
    private var stageTasks: [String: Task<Void, Never>] = [:]
    var stagingRepositories: Set<String> { Set(stageTasks.keys) }
    private(set) var stageErrors: [String: String] = [:]

    init(
        repositories: [WorkspaceRepository], reports: [URL: [ProviderReport]],
        defaults: UserDefaults = Preference.store,
        open: @escaping @MainActor (URL) -> Void
    ) {
        self.repositories = repositories
        self.reports = reports
        self.defaults = defaults
        self.open = open
        selected = Set(repositories.map(\.id))
        tab = Tab(rawValue: defaults.integer(forKey: Self.tabKey)) ?? .changes
    }

    deinit {
        changesTask?.cancel()
        branchTask?.cancel()
        timelineTask?.cancel()
        for task in stageTasks.values { task.cancel() }
    }

    func cancelAll() {
        changesTask?.cancel()
        timelineTask?.cancel()
        for task in stageTasks.values { task.cancel() }
        stageTasks.removeAll()
        stageErrors.removeAll()
        changes = .idle
        timeline = .idle
        if lockstep != .executing {
            branchTask?.cancel()
            lockstep = .idle
        }
    }

    func update(
        repositories: [WorkspaceRepository], reports: [URL: [ProviderReport]], open: @escaping @MainActor (URL) -> Void
    ) {
        if self.repositories != repositories {
            cancelAll()
            let ids = Set(repositories.map(\.id))
            selected = selected.intersection(ids).union(ids.subtracting(self.repositories.map(\.id)))
            self.repositories = repositories
        }
        self.reports = reports
        self.open = open
        timelineTask?.cancel()
        timeline = .idle
        if refresh() == nil { changed?() }
    }

    func select(_ next: Tab) {
        tab = next
        defaults.set(next.rawValue, forKey: Self.tabKey)
        switch next {
        case .changes where changes == .idle: refresh()
        case .timeline where timeline == .idle: refresh()
        default: changed?()
        }
    }

    @discardableResult func refresh() -> Task<Void, Never>? {
        switch tab {
        case .changes: refreshChanges()
        case .timeline: refreshTimeline()
        case .lockstep: branchName.isEmpty ? nil : preflight()
        }
    }

    private func refreshChanges() -> Task<Void, Never> {
        changesTask?.cancel()
        stageErrors.removeAll()
        changes = .loading
        changed?()
        let work = Task { [weak self, repositories, stageTasks] in
            for task in stageTasks.values { await task.value }
            guard !Task.isCancelled else { return }
            let rows = await WorkspaceChangesAggregator().collect(repositories)
            guard !Task.isCancelled else { return }
            self?.changes = rows.isEmpty ? .empty : .loaded(rows)
            self?.changed?()
        }
        changesTask = work
        return work
    }

    @discardableResult func stage(_ repo: WorkspaceRepository) -> Task<Void, Never>? {
        guard case .loaded(let rows) = changes, rows.first(where: { $0.repository == repo })?.canStageAll == true,
            stageTasks[repo.id] == nil
        else { return nil }
        stageErrors[repo.id] = nil
        let work = Task { [weak self] in
            do {
                let updated = try await WorkspaceChangesAggregator().stageAll(in: repo)
                try Task.checkCancellation()
                if case .loaded(let current) = self?.changes {
                    self?.changes = .loaded(current.map { $0.repository.id == repo.id ? updated : $0 })
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.stageErrors[repo.id] = error.localizedDescription
            }
            self?.stageTasks[repo.id] = nil
            self?.changed?()
        }
        stageTasks[repo.id] = work
        changed?()
        return work
    }

    private func refreshTimeline() -> Task<Void, Never> {
        timelineTask?.cancel()
        timeline = .loading
        changed?()
        let work = Task { [weak self, repositories, reports] in
            do {
                let events = try await WorkspaceTimelineBuilder().collect(repositories, reports: reports)
                try Task.checkCancellation()
                self?.timeline = events.isEmpty ? .empty : .loaded(events)
            } catch {
                guard !Task.isCancelled else { return }
                self?.timeline = .failed(error.localizedDescription)
            }
            self?.changed?()
        }
        timelineTask = work
        return work
    }

    var filteredEvents: [WorkspaceTimelineEvent] {
        guard case .loaded(let events) = timeline else { return [] }
        return events.filter { event in
            switch (filter, event.kind) {
            case (.all, _), (.commits, .commit), (.pullRequests, .pullRequest), (.deployments, .deployment): true
            default: false
            }
        }
    }

    func setFilter(_ value: Filter) {
        filter = value
        changed?()
    }
    func edit(branch: String, mode: LockstepBranchMode) {
        guard lockstep != .executing else { return }
        branchName = branch
        self.mode = mode
        invalidatePlan()
    }
    func toggle(_ repo: WorkspaceRepository) {
        guard lockstep != .executing else { return }
        if !selected.insert(repo.id).inserted { selected.remove(repo.id) }
        invalidatePlan()
    }
    private func invalidatePlan() {
        branchTask?.cancel()
        lockstep = .idle
        changed?()
    }

    @discardableResult func preflight() -> Task<Void, Never>? {
        guard lockstep != .executing, !selected.isEmpty, !branchName.isEmpty else { return nil }
        branchTask?.cancel()
        lockstep = .checking
        changed?()
        let repos = repositories.filter { selected.contains($0.id) }
        let work = Task { [weak self, branchName, mode] in
            let plan = await LockstepBranchService().preflight(branchName: branchName, mode: mode, repositories: repos)
            guard !Task.isCancelled else { return }
            self?.lockstep = .reviewed(plan)
            self?.changed?()
        }
        branchTask = work
        return work
    }

    @discardableResult func execute(allowWarnings: Bool) -> Task<Void, Never>? {
        guard case .reviewed(let plan) = lockstep else { return nil }
        lockstep = .executing
        changed?()
        let work = Task { [weak self] in
            let outcomes = await LockstepBranchService().execute(plan: plan, allowWarnings: allowWarnings)
            guard !Task.isCancelled else { return }
            self?.lockstep = .completed(outcomes)
            self?.changesTask?.cancel()
            self?.timelineTask?.cancel()
            self?.changes = .idle
            self?.timeline = .idle
            if self?.tab == .lockstep { self?.changed?() } else { self?.refresh() }
        }
        branchTask = work
        return work
    }
}
