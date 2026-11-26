import Foundation
import GitaCore

@MainActor public final class CommitBucketsPresenter {
    public private(set) var state = CommitBucketState.idle
    public private(set) var plan = CommitBucketPlan(items: [], buckets: [], baseHeadID: nil)
    public private(set) var selectedBucket: UUID?
    public private(set) var selectedItem: String?
    public var filterQuery = "" { didSet { onChange?() } }
    public private(set) var showsLoadingIndicator = false
    public private(set) var groupingNote: String?
    public var onChange: (() -> Void)?
    public var onCommitted: ((CommitBucketExecutionResult) -> Void)?
    public var isCommitting: Bool {
        if case .committing = state { return true }
        return false
    }
    var canEdit: Bool {
        switch state {
        case .editing, .failed(_, true): true
        default: false
        }
    }
    public var canUndo: Bool { !undoStack.isEmpty && canEdit }
    public var validationIssues: [BucketValidationIssue] { CommitBucketPlanner.validate(plan) }
    public var canCommit: Bool { canCommit(with: validationIssues) }
    func canCommit(with issues: [BucketValidationIssue]) -> Bool {
        canEdit && plan.buckets.contains { !$0.itemIDs.isEmpty } && issues.isEmpty
    }
    public var unassignedItems: [BucketHunkItem] {
        CommitBucketPlanner.unassignedItems(in: plan).filter {
            filterQuery.isEmpty || $0.path.localizedCaseInsensitiveContains(filterQuery)
                || $0.summary.localizedCaseInsensitiveContains(filterQuery)
        }
    }
    public var synthesizedDiff: String {
        if let selectedItem, let item = plan.items.first(where: { $0.id == selectedItem }) { return item.patch }
        guard let bucket = plan.buckets.first(where: { $0.id == selectedBucket }) else { return "" }
        return CommitBucketPlanner.synthesizedDiff(for: bucket, in: plan)
    }

    private let git: GitService
    private let agent: AgentTool?
    private let executor: CommitBucketExecutor
    private var undoStack: [CommitBucketPlan] = []
    private var messageBucket: UUID?
    private let work = LatestTask()
    private let indicator = LatestTask()
    private var generation = UUID()
    private var selectionKey = ""
    private var preferredBucketIndex: Int {
        get { UserDefaults.standard.integer(forKey: selectionKey) }
        set { UserDefaults.standard.set(newValue, forKey: selectionKey) }
    }

    public init(gitService: GitService, agent: AgentTool? = nil) {
        git = gitService
        self.agent = agent
        executor = CommitBucketExecutor(gitService: gitService)
    }

    public func load() {
        if case .committing = state { return }
        let previous = plan
        begin(.loading)
        work.run { [git] in
            let loaded = try await CommitBucketPlanner.loadPlan(from: git)
            return await (loaded, git.root.path)
        } then: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (loaded, path)):
                selectionKey = "Gita.CommitBucketsWindow.selection." + path
                plan = Self.restoringBuckets(from: previous, in: loaded)
                undoStack.removeAll()
                selectedBucket =
                    plan.buckets.indices.contains(preferredBucketIndex)
                    ? plan.buckets[preferredBucketIndex].id : plan.buckets.first?.id
                let savedItem = UserDefaults.standard.string(forKey: selectionKey + ".item")
                selectedItem = plan.items.first { $0.id == savedItem }?.id
                finish(.editing)
            case .failure(let error): finish(.failed(message: error.localizedDescription, canRetryCommit: false))
            }
        }
    }

    private static func restoringBuckets(
        from previous: CommitBucketPlan, in fresh: CommitBucketPlan
    ) -> CommitBucketPlan {
        guard previous.baseHeadID == fresh.baseHeadID, !previous.items.isEmpty else { return fresh }
        var restored = fresh
        let unchanged = Set(previous.items).intersection(fresh.items)
        let valid = Set(unchanged.map(\.id))
        restored.buckets = previous.buckets.map { bucket in
            var bucket = bucket
            bucket.itemIDs = bucket.itemIDs.filter(valid.contains)
            return bucket
        }
        return restored
    }

    public func selectBucket(_ id: UUID) {
        guard let index = plan.buckets.firstIndex(where: { $0.id == id }) else { return }
        if !selectionKey.isEmpty {
            if preferredBucketIndex != index { preferredBucketIndex = index }
            UserDefaults.standard.removeObject(forKey: selectionKey + ".item")
        }
        if selectedBucket != id { messageBucket = nil }
        selectedBucket = id
        selectedItem = nil
        onChange?()
    }

    public func selectItem(_ id: String) {
        guard plan.items.contains(where: { $0.id == id }) else { return }
        if !selectionKey.isEmpty { UserDefaults.standard.set(id, forKey: selectionKey + ".item") }
        selectedItem = id
        onChange?()
    }

    public func addBucket() {
        guard canEdit else { return }
        apply(CommitBucketPlanner.addBucket(to: plan))
        if let id = plan.buckets.last?.id { selectBucket(id) }
    }
    public func removeBucket(_ id: UUID) { apply(CommitBucketPlanner.removeBucket(id, from: plan)) }
    public func moveBucket(from: Int, to: Int) { apply(CommitBucketPlanner.moveBucket(from: from, to: to, in: plan)) }
    public func updateMessage(_ id: UUID, title: String, body: String) {
        apply(CommitBucketPlanner.updateBucketMessage(id, title: title, body: body, in: plan), messageBucket: id)
    }
    public func assign(itemID: String, to id: UUID) {
        guard canEdit else { return }
        apply(CommitBucketPlanner.assign(itemID: itemID, to: id, in: plan))
        selectBucket(id)
    }
    public func assignFile(path: String, to id: UUID) {
        guard canEdit else { return }
        apply(CommitBucketPlanner.assignFile(path: path, to: id, in: plan))
        selectBucket(id)
    }
    public func unassign(_ id: String) { apply(CommitBucketPlanner.unassign(itemID: id, in: plan)) }

    private func apply(_ next: CommitBucketPlan, messageBucket id: UUID? = nil) {
        guard canEdit, plan != next else { return }
        if id == nil || messageBucket != id {
            undoStack.append(plan)
            if undoStack.count > 30 { undoStack.removeFirst() }
        }
        messageBucket = id
        replace(next)
    }
    private func replace(_ next: CommitBucketPlan) {
        state = .editing
        plan = next
        if !plan.buckets.contains(where: { $0.id == selectedBucket }) { selectedBucket = plan.buckets.first?.id }
        selectedItem = nil
        onChange?()
    }
    public func undo() {
        guard canUndo, let previous = undoStack.popLast() else { return }
        messageBucket = nil
        replace(previous)
    }

    public func autoGroup() {
        guard canEdit, !plan.items.isEmpty else { return }
        let items = plan.items
        begin(.suggesting)
        work.run { [agent, git] in
            await CommitBucketAgentSuggester().suggest(items: items, tool: agent, directory: git.root)
        } then: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let groups):
                groupingNote = groups.fallbackReason
                var next = plan
                next.buckets = groups.suggestions.map { .init(title: $0.title, body: $0.body, itemIDs: $0.itemIDs) }
                finish(.editing)
                apply(next)
            case .failure(let error):
                groupingNote = error.localizedDescription
                finish(.editing)
            }
        }
    }

    public func commit() {
        guard canCommit else { return }
        let total = plan.buckets.count { !$0.itemIDs.isEmpty }
        begin(.committing(step: 0, total: total))
        let token = generation
        Task { [self, plan] in
            do {
                let result = try await executor.execute(plan: plan) { [weak self] step, total in
                    Task { @MainActor [weak self] in
                        guard let self, token == generation, isCommitting else { return }
                        state = .committing(step: step, total: total)
                        onChange?()
                    }
                }
                undoStack.removeAll()
                finish(.completed(result))
                onCommitted?(result)
            } catch {
                finish(.failed(message: error.localizedDescription, canRetryCommit: true))
            }
        }
    }

    private func begin(_ next: CommitBucketState) {
        generation = UUID()
        messageBucket = nil
        groupingNote = nil
        state = next
        showsLoadingIndicator = false
        indicator.run {
            try await Task.sleep(for: .milliseconds(150))
        } then: { [weak self] _ in
            self?.showsLoadingIndicator = true
            self?.onChange?()
        }
        onChange?()
    }
    private func finish(_ next: CommitBucketState) {
        indicator.cancel()
        showsLoadingIndicator = false
        state = next
        onChange?()
    }
    public func cancel() { cancelBackgroundWork() }

    public func cancelBackgroundWork() {
        switch state {
        case .suggesting, .loading:
            work.cancel()
            finish(state == .suggesting ? .editing : .idle)
        default: break
        }
    }
}
