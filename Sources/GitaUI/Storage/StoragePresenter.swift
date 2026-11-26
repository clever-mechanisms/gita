import Foundation
import GitaCore

struct StorageBarSegment: Equatable {
    enum ColorRole { case gitStore, reclaimable, workingTrees }
    let colorRole: ColorRole
    let fraction: Double
    let tooltip: String
}

struct StorageOutlineNode: Equatable {
    let title: String
    let url: URL
    let bytes: UInt64
    var branch: String?
    var warning: String?
    var caption: String?
    var checkout: CheckoutStorageReport?
    var entry: HeavyFolderEntry?
    var children: [Self] = []
    var isSelectable: Bool { entry?.status == .reclaimable }
}

struct StorageWorkspaceRow: Equatable {
    let root: URL
    let name: String
    let totalBytes: UInt64
    let reclaimableBytes: UInt64
    let worktreeCount: Int
    let share: Double
}

struct StorageTrashPlan: Equatable {
    struct Group: Equatable {
        let checkout: URL
        let entries: [HeavyFolderEntry]
    }
    let groups: [Group]
    let activeAgentNames: [String]
    let skippedActiveCount: Int
    var paths: [String] { groups.flatMap { $0.entries.map { $0.url.path } } }
}

struct StoragePresenter {
    func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    func summarySegments(for report: RepositoryStorageReport) -> [StorageBarSegment] {
        let git = report.gitStore.totalAllocatedBytes
        let reclaimable = report.reclaimableBytes
        func segment(_ role: StorageBarSegment.ColorRole, _ label: String, _ bytes: UInt64) -> StorageBarSegment {
            let size = formatBytes(bytes)
            return StorageBarSegment(
                colorRole: role,
                fraction: Double(bytes) / Double(max(1, report.totalAllocatedBytes)),
                tooltip: String(localized: "\(label) · \(size)"))
        }
        return [
            segment(.gitStore, String(localized: "Git Store"), git),
            segment(.reclaimable, String(localized: "Reclaimable Bloat"), reclaimable),
            segment(
                .workingTrees, String(localized: "Working Trees / Other"),
                report.totalAllocatedBytes - git - reclaimable),
        ]
    }

    func activeCheckoutIDs(in report: RepositoryStorageReport, activeAgentPaths: Set<String>) -> Set<String> {
        let paths = report.checkouts.map(\.id).sorted { $0.count > $1.count }
        return Set(
            activeAgentPaths.compactMap { path -> String? in
                paths.first { path == $0 || path.hasPrefix($0 + "/") }
            })
    }

    func hasActiveAgent(
        in root: URL, snapshot: RepositoryHealthSnapshot?, report: RepositoryStorageReport?,
        activeAgentPaths: Set<String>
    ) -> Bool {
        guard !activeAgentPaths.isEmpty else { return false }
        var known = Set<String>()
        if let snapshot { known.formUnion(snapshot.worktreePaths) }
        if let report { known.formUnion(report.checkouts.map(\.id)) }
        // When linked worktrees are unknown, fail safe so immediate GC pruning does not race an external worktree.
        guard !known.isEmpty else { return true }
        known.insert(root.resolvingSymlinksInPath().standardizedFileURL.path)
        return activeAgentPaths.contains { agent in
            known.contains { agent == $0 || agent.hasPrefix($0 + "/") }
        }
    }

    func trashPlan(
        report: RepositoryStorageReport, entry: HeavyFolderEntry?, checked: Set<String>, activeAgentPaths: Set<String>
    ) -> StorageTrashPlan {
        let activeIDs = activeCheckoutIDs(in: report, activeAgentPaths: activeAgentPaths)
        let explicit = entry.map { Set([$0.id]) } ?? checked
        let isBulkDefault = explicit.isEmpty
        var groups = [StorageTrashPlan.Group]()
        var activeNames = [String]()
        var skipped = 0
        for checkout in report.checkouts {
            let entries = checkout.heavyFolders.filter {
                $0.status == .reclaimable && (isBulkDefault || explicit.contains($0.id))
            }
            guard !entries.isEmpty else { continue }
            if activeIDs.contains(checkout.id) {
                if isBulkDefault {
                    skipped += 1
                    continue
                }
                activeNames.append(checkout.displayName)
            }
            groups.append(StorageTrashPlan.Group(checkout: checkout.path, entries: entries))
        }
        return StorageTrashPlan(groups: groups, activeAgentNames: activeNames, skippedActiveCount: skipped)
    }

    func outlineNodes(
        for report: RepositoryStorageReport, activeAgentPaths: Set<String>, now: Date
    )
        -> [StorageOutlineNode]
    {
        let active = activeCheckoutIDs(in: report, activeAgentPaths: activeAgentPaths)
        return [storeNode(report.gitStore)]
            + report.checkouts.sorted {
                ($1.totalAllocatedBytes, $0.id) < ($0.totalAllocatedBytes, $1.id)
            }.map { tree in
                let running = active.contains(tree.id)
                let caption =
                    tree.isUnavailable
                    ? String(localized: "Unavailable (not mounted)")
                    : staleness(tree.lastModifiedDate, now: now)
                return StorageOutlineNode(
                    title: tree.displayName, url: tree.path, bytes: tree.totalAllocatedBytes,
                    branch: tree.branch, warning: running ? String(localized: "An agent is active here.") : nil,
                    caption: caption, checkout: tree,
                    children: tree.heavyFolders.sorted {
                        ($1.allocatedBytes, $0.id) < ($0.allocatedBytes, $1.id)
                    }.map { entry in
                        StorageOutlineNode(
                            title: entry.relativePath, url: entry.url, bytes: entry.allocatedBytes,
                            caption: folderCaption(entry), entry: entry)
                    })
            }
    }

    func workspaceRows(for reports: [RepositoryStorageReport]) -> [StorageWorkspaceRow] {
        let sorted = reports.sorted { ($1.totalAllocatedBytes, $0.id) < ($0.totalAllocatedBytes, $1.id) }
        let largest = Double(max(1, sorted.first?.totalAllocatedBytes ?? 0))
        return sorted.map {
            StorageWorkspaceRow(
                root: $0.mainRoot, name: $0.repositoryName, totalBytes: $0.totalAllocatedBytes,
                reclaimableBytes: $0.reclaimableBytes, worktreeCount: $0.checkouts.filter { !$0.isBare }.count,
                share: Double($0.totalAllocatedBytes) / largest)
        }
    }

    private func folderCaption(_ entry: HeavyFolderEntry) -> String {
        let files = entry.fileCount == 1 ? String(localized: "1 file") : String(localized: "\(entry.fileCount) files")
        switch entry.status {
        case .reclaimable: return String(localized: "\(entry.category.displayName) · \(files) · Reclaimable")
        case .trackedOrUnignored: return String(localized: "\(entry.category.displayName) · \(files) · Protected")
        case .otherLarge: return String(localized: "\(entry.category.displayName) · \(files)")
        }
    }

    private func storeNode(_ store: GitStoreBreakdown) -> StorageOutlineNode {
        let url = store.gitCommonDirectory
        func child(_ name: String, _ path: URL, _ bytes: UInt64) -> StorageOutlineNode {
            StorageOutlineNode(title: name, url: path, bytes: bytes)
        }
        return StorageOutlineNode(
            title: String(localized: ".git store"), url: url, bytes: store.totalAllocatedBytes,
            children: [
                child(String(localized: "Objects"), url.appendingPathComponent("objects"), store.objectsAllocatedBytes),
                child(String(localized: "LFS"), url.appendingPathComponent("lfs"), store.lfsAllocatedBytes),
                child(String(localized: "Worktrees and other"), url, store.worktreesAndOtherAllocatedBytes),
            ])
    }

    private func staleness(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let days = max(0, Int(now.timeIntervalSince(date) / 86_400))
        if days >= 30 { return String(localized: "Stale · \(days)d ago") }
        return days == 0 ? String(localized: "Modified today") : String(localized: "Modified \(days)d ago")
    }
}
