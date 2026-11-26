import Foundation
import GitaCore

struct StorageBarSegment: Equatable {
    enum ColorRole { case gitStore, reclaimable, workingTrees }
    let colorRole: ColorRole
    let label: String
    let formattedBytes: String
    let fraction: Double
    let percentText: String
    let tooltip: String
}

struct StorageOutlineNode: Equatable {
    enum Kind: Equatable {
        case gitStore, gitStoreObjects, gitStoreLFS, gitStoreOther
        case mainCheckout, worktree, heavyFolder
    }

    enum Tone: Equatable {
        case blue, teal, accent, indigo, green, orange, neutral
    }

    let title: String
    let url: URL
    let bytes: UInt64
    var kind: Kind = .heavyFolder
    var branch: String?
    var warning: String?
    var caption: String?
    var reclaimableBytes: UInt64 = 0
    var share: Double = 0
    var checkout: CheckoutStorageReport?
    var entry: HeavyFolderEntry?
    var children: [Self] = []

    var isSelectable: Bool { entry?.status == .reclaimable }
    var isTopLevel: Bool { kind == .gitStore || kind == .mainCheckout || kind == .worktree }

    var symbolName: String {
        switch kind {
        case .gitStore: "cylinder.split.1x2.fill"
        case .gitStoreObjects: "archivebox.fill"
        case .gitStoreLFS: "externaldrive.fill"
        case .gitStoreOther: "doc.text.fill"
        case .mainCheckout: "folder.fill"
        case .worktree: Deck.worktreeSymbol
        case .heavyFolder: Self.heavyFolderSymbol(for: entry)
        }
    }

    var tone: Tone {
        switch kind {
        case .gitStore, .gitStoreObjects: .blue
        case .gitStoreLFS: .teal
        case .gitStoreOther: .neutral
        case .mainCheckout: .accent
        case .worktree: .indigo
        case .heavyFolder: Self.heavyFolderTone(for: entry?.status)
        }
    }

    private static let packageFolders: Set<String> = [
        "node_modules", ".pnpm-store", "pods", "vendor", ".yarn", "bower_components", ".gradle",
    ]

    static func heavyFolderSymbol(for entry: HeavyFolderEntry?) -> String {
        guard let entry else { return "folder.fill" }
        if packageFolders.contains(entry.url.lastPathComponent.lowercased()) { return "shippingbox.fill" }
        switch entry.category {
        case .javascript: return "shippingbox.fill"
        case .swift, .rust, .jvm, .buildOutput: return "hammer.fill"
        case .python, .cache, .infrastructure: return "cube.fill"
        case .otherLarge: return "folder.fill"
        }
    }

    private static func heavyFolderTone(for status: HeavyFolderStatus?) -> Tone {
        switch status {
        case .reclaimable: .green
        case .trackedOrUnignored: .orange
        default: .neutral
        }
    }
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

    func formatPercent(_ fraction: Double) -> String {
        let pct = fraction * 100
        if pct > 0, pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }

    func summarySegments(for report: RepositoryStorageReport) -> [StorageBarSegment] {
        let git = report.gitStore.totalAllocatedBytes
        let reclaimable = report.reclaimableBytes
        let working =
            report.totalAllocatedBytes > git + reclaimable ? report.totalAllocatedBytes - git - reclaimable : 0
        func segment(_ role: StorageBarSegment.ColorRole, _ label: String, _ bytes: UInt64) -> StorageBarSegment {
            let size = formatBytes(bytes)
            let fraction = Double(bytes) / Double(max(1, report.totalAllocatedBytes))
            return StorageBarSegment(
                colorRole: role, label: label, formattedBytes: size,
                fraction: fraction, percentText: formatPercent(fraction),
                tooltip: String(localized: "\(label) · \(size)"))
        }
        return [
            segment(.gitStore, String(localized: "Git Store"), git),
            segment(.reclaimable, String(localized: "Reclaimable Bloat"), reclaimable),
            segment(.workingTrees, String(localized: "Working Trees / Other"), working),
        ]
    }

    func selectedBytes(for checked: Set<String>, in report: RepositoryStorageReport) -> UInt64 {
        report.checkouts
            .flatMap(\.heavyFolders)
            .filter { checked.contains($0.id) }
            .reduce(0) { $0 + $1.allocatedBytes }
    }

    func summarySubtitle(for report: RepositoryStorageReport) -> String {
        let count = report.checkouts.filter { !$0.isBare }.count
        let checkouts = count == 1 ? String(localized: "1 checkout") : String(localized: "\(count) checkouts")
        guard report.reclaimableBytes > 0 else {
            return String(localized: "\(checkouts) · No reclaimable bloat")
        }
        let reclaimable = formatBytes(report.reclaimableBytes)
        return String(localized: "\(checkouts) · \(reclaimable) reclaimable")
    }

    func cleanButtonTitle(selectedPaths: Set<String>, in report: RepositoryStorageReport) -> String {
        if !selectedPaths.isEmpty {
            let size = formatBytes(selectedBytes(for: selectedPaths, in: report))
            return String(localized: "Clean \(size)…")
        }
        guard report.reclaimableBytes > 0 else { return String(localized: "Clean…") }
        let size = formatBytes(report.reclaimableBytes)
        return String(localized: "Clean \(size)…")
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
    ) -> [StorageOutlineNode] {
        let active = activeCheckoutIDs(in: report, activeAgentPaths: activeAgentPaths)
        let maxRoot = Double(
            max(1, max(report.gitStore.totalAllocatedBytes, report.checkouts.map(\.totalAllocatedBytes).max() ?? 0)))
        let checkoutNodes = report.checkouts.sorted {
            ($1.totalAllocatedBytes, $0.id) < ($0.totalAllocatedBytes, $1.id)
        }.map { checkoutNode($0, active: active, maxRoot: maxRoot, now: now) }
        return [storeNode(report.gitStore, maxRoot: maxRoot)] + checkoutNodes
    }

    private func checkoutNode(
        _ tree: CheckoutStorageReport, active: Set<String>, maxRoot: Double, now: Date
    ) -> StorageOutlineNode {
        let running = active.contains(tree.id)
        let caption =
            tree.isUnavailable
            ? String(localized: "Unavailable (not mounted)")
            : staleness(tree.lastModifiedDate, now: now)
        let parentDenominator = Double(max(1, tree.totalAllocatedBytes))
        let children = tree.heavyFolders.sorted {
            ($1.allocatedBytes, $0.id) < ($0.allocatedBytes, $1.id)
        }.map { entry in
            StorageOutlineNode(
                title: entry.relativePath, url: entry.url, bytes: entry.allocatedBytes,
                kind: .heavyFolder, caption: folderCaption(entry),
                share: Double(entry.allocatedBytes) / parentDenominator, entry: entry)
        }
        return StorageOutlineNode(
            title: tree.displayName, url: tree.path, bytes: tree.totalAllocatedBytes,
            kind: tree.isMainWorktree ? .mainCheckout : .worktree,
            branch: tree.branch, warning: running ? String(localized: "An agent is active here.") : nil,
            caption: caption, reclaimableBytes: tree.reclaimableBytes,
            share: Double(tree.totalAllocatedBytes) / maxRoot, checkout: tree, children: children)
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
        return String(localized: "\(entry.category.displayName) · \(files)")
    }

    private func storeNode(_ store: GitStoreBreakdown, maxRoot: Double) -> StorageOutlineNode {
        let url = store.gitCommonDirectory
        let parentTotal = Double(max(1, store.totalAllocatedBytes))
        func child(
            _ name: String, _ path: URL, _ bytes: UInt64, _ kind: StorageOutlineNode.Kind
        ) -> StorageOutlineNode {
            StorageOutlineNode(
                title: name, url: path, bytes: bytes, kind: kind, share: Double(bytes) / parentTotal)
        }
        return StorageOutlineNode(
            title: String(localized: ".git store"), url: url, bytes: store.totalAllocatedBytes,
            kind: .gitStore, share: Double(store.totalAllocatedBytes) / maxRoot,
            children: [
                child(
                    String(localized: "Objects"), url.appendingPathComponent("objects"),
                    store.objectsAllocatedBytes, .gitStoreObjects),
                child(
                    String(localized: "LFS"), url.appendingPathComponent("lfs"),
                    store.lfsAllocatedBytes, .gitStoreLFS),
                child(
                    String(localized: "Worktrees and other"), url,
                    store.worktreesAndOtherAllocatedBytes, .gitStoreOther),
            ])
    }

    private func staleness(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let days = max(0, Int(now.timeIntervalSince(date) / 86_400))
        if days >= 30 { return String(localized: "Stale · \(days)d ago") }
        return days == 0 ? String(localized: "Modified today") : String(localized: "Modified \(days)d ago")
    }
}
