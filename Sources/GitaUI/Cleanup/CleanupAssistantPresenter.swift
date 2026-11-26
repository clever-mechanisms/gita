import Foundation
import GitaCore

enum CleanupFilter: String, CaseIterable, Sendable {
    case all
    case merged
    case goneUpstream
    case stale
    case worktrees

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .merged: String(localized: "Merged")
        case .goneUpstream: String(localized: "Gone Upstream")
        case .stale: String(localized: "Stale")
        case .worktrees: String(localized: "Worktrees")
        }
    }

    var symbolName: String {
        switch self {
        case .all: "tray.full"
        case .merged: "arrow.triangle.merge"
        case .goneUpstream: "icloud.slash"
        case .stale: "clock"
        case .worktrees: "square.stack.3d.up"
        }
    }
}

enum CleanupBadge: Equatable, Sendable {
    case merged
    case goneUpstream
    case stale
    case unmergedWarning
    case dirtyWarning
    case prunable
    case failed

    var title: String {
        switch self {
        case .merged: CleanupFilter.merged.title
        case .goneUpstream: CleanupFilter.goneUpstream.title
        case .stale: CleanupFilter.stale.title
        case .unmergedWarning: String(localized: "Unmerged")
        case .dirtyWarning: String(localized: "Dirty")
        case .prunable: String(localized: "Prunable")
        case .failed: String(localized: "Failed")
        }
    }

    var symbolName: String {
        switch self {
        case .merged: "checkmark.circle.fill"
        case .goneUpstream: "icloud.slash"
        case .stale: "clock"
        case .unmergedWarning: "exclamationmark.triangle.fill"
        case .dirtyWarning: "exclamationmark.circle.fill"
        case .prunable: "xmark.bin"
        case .failed: "xmark.circle.fill"
        }
    }
}

struct CleanupRowItem: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let shortCommit: String?
    let isWorktree: Bool
    let badges: [CleanupBadge]
    let days: Int
    let isSelected: Bool
    let failureReason: String?

    var isFailure: Bool { failureReason != nil }
    var displayTitle: String {
        guard isWorktree else { return title }
        if let subtitle, !subtitle.isEmpty { return subtitle }
        let name = URL(fileURLWithPath: title).lastPathComponent
        return name.isEmpty ? title : name
    }
    var detailText: String {
        if let failureReason { return failureReason }
        if isWorktree { return worktreeDetail }
        return branchDetail
    }
    var ageText: String {
        if days == 0 { return String(localized: "Today") }
        return days < 60 ? String(localized: "\(days)d") : String(localized: "\(days / 30)mo")
    }
    var warning: String? {
        if let failureReason { return failureReason }
        if badges.contains(.dirtyWarning) { return String(localized: "Git will refuse to remove a dirty worktree.") }
        if badges.contains(.unmergedWarning) { return String(localized: "Deleting this branch could discard commits.") }
        return nil
    }

    private var worktreeDetail: String {
        var parts = [Self.abbreviateHome(title)]
        if subtitle == nil { parts.append(String(localized: "Detached HEAD")) }
        if badges.contains(.dirtyWarning) { parts.append(String(localized: "Uncommitted changes")) }
        if badges.contains(.prunable) { parts.append(String(localized: "Directory missing")) }
        return parts.joined(separator: " · ")
    }

    private var branchDetail: String {
        var parts: [String] = []
        if let shortCommit, !shortCommit.isEmpty { parts.append(shortCommit) }
        if badges.contains(.merged) {
            parts.append(String(localized: "Merged branch"))
        } else if badges.contains(.goneUpstream) {
            parts.append(String(localized: "Upstream branch removed"))
        } else if badges.contains(.stale) {
            parts.append(String(localized: "Inactive branch"))
        }
        return parts.joined(separator: " · ")
    }

    static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty else { return path }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }

    func matches(_ filter: CleanupFilter) -> Bool {
        switch filter {
        case .all: true
        case .merged: badges.contains(.merged)
        case .goneUpstream: badges.contains(.goneUpstream)
        case .stale: badges.contains(.stale)
        case .worktrees: isWorktree
        }
    }
}

struct CleanupAssistantPresenter {
    private(set) var scanState = CleanupScanState.idle
    private(set) var runState = CleanupRunState.idle
    var activeFilter = CleanupFilter.all
    private(set) var selectedBranchIDs: Set<String> = []
    private(set) var selectedWorktreeIDs: Set<String> = []
    private(set) var failuresByTarget: [String: String] = [:]

    var selectionCount: Int { selectedBranchIDs.count + selectedWorktreeIDs.count }
    var isCleaning: Bool {
        if case .cleaning = runState { return true }
        return false
    }
    var isBusy: Bool { scanState.isScanning || isCleaning }
    var isAllVisibleSelected: Bool {
        let rows = visibleRows()
        return !rows.isEmpty && rows.allSatisfy(\.isSelected)
    }
    var hasStatusError: Bool {
        switch runState {
        case .failed: true
        case .completed(let result): !result.failures.isEmpty
        case .idle, .cleaning: false
        }
    }
    var selectionText: String {
        let total = rows().count
        if selectionCount == 0 {
            return total == 0
                ? String(localized: "0 selected")
                : String(localized: "0 of \(total) selected")
        }
        return String(localized: "\(selectionCount) of \(total) selected")
    }
    var actionButtonTitle: String {
        switch selectionCount {
        case 0: String(localized: "Clean Selected…")
        case 1: String(localized: "Clean 1 Item…")
        default: String(localized: "Clean \(selectionCount) Items…")
        }
    }
    var status: String {
        switch runState {
        case .idle: return ""
        case .cleaning(let count): return String(localized: "Cleaning \(count) selected items…")
        case .failed(let message): return message
        case .completed(let result):
            let count = result.deletedBranches.count + result.removedWorktrees.count
            let removed = String(localized: "Removed \(count) items.")
            if result.failures.isEmpty { return removed }
            return removed + " " + String(localized: "Failed to clean \(result.failures.count) items.")
        }
    }

    @discardableResult mutating func startScan(clearFailures: Bool = true) -> UUID {
        let id = UUID()
        scanState = .scanning(id: id)
        selectedBranchIDs.removeAll()
        selectedWorktreeIDs.removeAll()
        if clearFailures { failuresByTarget.removeAll() }
        return id
    }
    mutating func completeScan(_ report: CleanupScanReport, id: UUID) {
        guard scanState == .scanning(id: id) else { return }
        scanState = .loaded(report)
    }
    mutating func failScan(_ message: String, id: UUID) {
        guard scanState == .scanning(id: id) else { return }
        scanState = .failed(message)
    }
    mutating func startCleanup() {
        failuresByTarget.removeAll()
        runState = .cleaning(count: selectionCount)
    }
    mutating func completeCleanup(_ result: CleanupBatchResult) {
        failuresByTarget = Dictionary(
            result.failures.map { ($0.target, $0.reason) }, uniquingKeysWith: { first, _ in first })
        runState = .completed(result)
    }
    mutating func failCleanup(_ message: String) { runState = .failed(message) }

    func filterCount(for filter: CleanupFilter) -> Int { rows().count { $0.matches(filter) } }
    func visibleRows() -> [CleanupRowItem] { rows().filter { $0.matches(activeFilter) } }

    private func rows() -> [CleanupRowItem] {
        guard let report = scanState.report else { return [] }
        let branches = report.branches.map { branch in
            var badges = branch.reasons.map { reason -> CleanupBadge in
                switch reason {
                case .merged: .merged
                case .goneUpstream: .goneUpstream
                case .stale: .stale
                }
            }
            if branch.requiresForceToDelete { badges.append(.unmergedWarning) }
            let failure = failuresByTarget[branch.name]
            if failure != nil { badges.append(.failed) }
            return CleanupRowItem(
                id: branch.id, title: branch.name, subtitle: nil, shortCommit: String(branch.commit.prefix(8)),
                isWorktree: false, badges: badges, days: branch.ageDays,
                isSelected: selectedBranchIDs.contains(branch.id), failureReason: failure)
        }
        return branches
            + report.worktrees.map { tree in
                var badges: [CleanupBadge] = tree.isPrunable ? [.prunable] : []
                if tree.isDirty { badges.append(.dirtyWarning) }
                let failure = failuresByTarget[tree.path]
                if failure != nil { badges.append(.failed) }
                return CleanupRowItem(
                    id: tree.id, title: tree.path, subtitle: tree.branch, shortCommit: nil, isWorktree: true,
                    badges: badges, days: tree.idleDays, isSelected: selectedWorktreeIDs.contains(tree.id),
                    failureReason: failure)
            }
    }

    mutating func toggleSelection(id: String) {
        guard !isBusy, let row = visibleRows().first(where: { $0.id == id }) else { return }
        setSelected(!row.isSelected, row: row)
    }
    mutating func selectAllVisible() {
        guard !isBusy else { return }
        for row in visibleRows() { setSelected(true, row: row) }
    }
    mutating func deselectAllVisible() {
        guard !isBusy else { return }
        for row in visibleRows() { setSelected(false, row: row) }
    }
    private mutating func setSelected(_ selected: Bool, row: CleanupRowItem) {
        let key = row.isWorktree ? \Self.selectedWorktreeIDs : \Self.selectedBranchIDs
        if selected { self[keyPath: key].insert(row.id) } else { self[keyPath: key].remove(row.id) }
    }

    func buildBatchSelection(allowUnmergedBranchDelete: Bool = false) -> CleanupBatchSelection {
        let branches = scanState.report?.branches ?? []
        let pinned = Dictionary(
            uniqueKeysWithValues: branches.filter { selectedBranchIDs.contains($0.id) }.map { ($0.name, $0.commit) })
        return CleanupBatchSelection(
            branches: pinned, worktreePaths: selectedWorktreeIDs.sorted(),
            allowUnmergedBranchDelete: allowUnmergedBranchDelete)
    }
    var includesUnmerged: Bool {
        rows().contains { $0.isSelected && $0.badges.contains(.unmergedWarning) }
    }
    func confirmationSummary() -> String {
        let selection = buildBatchSelection()
        var sections: [String] = []
        if !selection.branches.isEmpty {
            sections.append(
                ([String(localized: "Delete branches")] + selection.branches.keys.sorted()).joined(separator: "\n"))
        }
        if !selection.worktreePaths.isEmpty {
            let notice = String(
                localized:
                    "Removing a worktree also deletes ignored files inside it (such as .env or build folders).")
            sections.append(
                ([String(localized: "Remove worktrees")] + selection.worktreePaths + [notice]).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
    static func failureDetails(for result: CleanupBatchResult) -> String {
        result.failures.map { "\($0.target) — \($0.reason)" }.joined(separator: "\n")
    }
}
