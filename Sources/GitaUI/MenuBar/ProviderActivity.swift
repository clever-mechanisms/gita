import Foundation
import GitaCore

/// The latest provider reports of every repository that has been open in a tab this session, for the menu bar
/// panel's inbox and Activity page and the menu bar attention dot. Nothing here polls: tabs publish, this listens.
@MainActor
final class ProviderActivity {
    static let shared = ProviderActivity()
    struct Entry {
        var root: URL
        var commonGitDirectory: URL
        var branch: String?
        var reports: [ProviderKind: ProviderReport] = [:]
        var items: [ProviderItem] { reports.values.flatMap(\.items) }
        var checkedAt: Date? { reports.values.map(\.checkedAt).max() }
    }
    private(set) var entries: [String: Entry] = [:]
    /// Keys in the order they last reported, oldest first, so the store stays bounded.
    private var recency: [String] = []
    private let entryLimit: Int
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var pendingNotify = false

    init(entryLimit: Int = 64) { self.entryLimit = entryLimit }

    func record(_ report: ProviderReport, snapshot: RepositorySnapshot) {
        let key = Self.key(snapshot.root)
        var entry =
            entries[key]
            ?? Entry(root: snapshot.root, commonGitDirectory: snapshot.commonGitDirectory, branch: snapshot.branch)
        entry.commonGitDirectory = snapshot.commonGitDirectory
        entry.branch = snapshot.branch
        entry.reports[report.provider] = report
        entries[key] = entry
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > entryLimit { entries[recency.removeFirst()] = nil }
        // Reports of one refresh arrive together; observers hear about them once.
        guard !pendingNotify else { return }
        pendingNotify = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingNotify = false
                for observer in Array(self.observers.values) { observer() }
            }
        }
    }

    @discardableResult func observe(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil }

    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// The entry for a repository's main checkout, or for any of its worktrees that was opened instead.
    func entry(for root: URL) -> Entry? {
        let key = Self.key(root)
        if let entry = entries[key] { return entry }
        let common = Self.key(root.appendingPathComponent(".git"))
        return entries.values.filter { Self.key($0.commonGitDirectory) == common }.max {
            ($0.checkedAt ?? .distantPast) < ($1.checkedAt ?? .distantPast)
        }
    }

    var checkedAt: Date? { entries.values.compactMap(\.checkedAt).max() }

    /// Newest events across repositories: PR opened/merged/review requested, checks failed/fixed, deployments ready,
    /// agents finished/needing input. Bounded to the last 7 days and 40 rows.
    func feed(sessions: [AgentSession], names: [String: String], now: Date = Date()) -> [FeedEvent] {
        var events: [FeedEvent] = []
        for entry in entries.values {
            let name = names[Self.key(entry.root)] ?? entry.root.lastPathComponent
            events += ProviderFeed.events(
                entry.items, repository: entry.root, name: name, vercel: entry.reports[.vercel]?.vercel)
        }
        events += ProviderFeed.agentEvents(sessions, names: names)
        return ProviderFeed.newest(events, now: now)
    }

    /// The broken provider line with its full diagnostic tooltip and primary repository to open when clicked.
    /// Multiple checkouts or worktrees of the same GitHub repository count once.
    func problemDetail(names: [String: String]) -> MenuPanelState.Problem? {
        let broken = brokenEntries(names: names)
        guard let first = broken.first else {
            // Vercel's own incident, once, while any open repository deploys there.
            let platform = entries.values.lazy.compactMap { $0.reports[.vercel]?.vercelSignals?.platform }.first {
                $0.isDegraded
            }
            guard let platform else { return nil }
            let text = "Vercel · " + VercelSignalText.platform(platform)
            let summary = platform.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return MenuPanelState.Problem(
                text: text, toolTip: summary.isEmpty ? text : summary, repository: nil, provider: nil)
        }
        let provider = first.provider == .github ? "GitHub" : "Vercel"
        let status = first.status.localizedTitle
        let text =
            broken.count == 1
            ? String(localized: "\(provider) · \(status) · \(first.name)")
            : String(localized: "\(provider) · \(status) · \(broken.count) repositories")
        let toolTip = Self.problemToolTip(broken: broken, fallback: text)
        return MenuPanelState.Problem(
            text: text, toolTip: toolTip, repository: first.root, provider: first.provider)
    }

    private struct BrokenEntry {
        var provider: ProviderKind
        var status: ProviderStatus
        var name: String
        var root: URL
        var diagnostic: String?
    }

    private func brokenEntries(names: [String: String]) -> [BrokenEntry] {
        let ordered = entries.values.sorted { lhs, rhs in
            let lhsMain = Self.key(lhs.commonGitDirectory) == Self.key(lhs.root.appendingPathComponent(".git"))
            let rhsMain = Self.key(rhs.commonGitDirectory) == Self.key(rhs.root.appendingPathComponent(".git"))
            if lhsMain != rhsMain { return lhsMain }
            return lhs.root.path < rhs.root.path
        }
        var seenGitHubSourceIDs = Set<String>()
        var seenGitHubCommonDirs = Set<String>()
        var broken: [BrokenEntry] = []
        for entry in ordered {
            let name = names[Self.key(entry.root)] ?? entry.root.lastPathComponent
            let commonKey = Self.key(entry.commonGitDirectory)
            for provider in [ProviderKind.github, .vercel] {
                guard let report = entry.reports[provider], report.status.isBroken else { continue }
                if provider == .github {
                    if let sourceID = report.sourceID, !seenGitHubSourceIDs.insert(sourceID).inserted { continue }
                    if !seenGitHubCommonDirs.insert(commonKey).inserted { continue }
                }
                broken.append(
                    BrokenEntry(
                        provider: provider, status: report.status, name: name, root: entry.root,
                        diagnostic: report.diagnostic))
            }
        }
        return broken
    }

    private static func problemToolTip(broken: [BrokenEntry], fallback: String) -> String {
        if broken.count == 1 {
            let diagnostic = broken[0].diagnostic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return diagnostic.isEmpty ? fallback : diagnostic
        }
        let lines = broken.map { item in
            let diagnostic = item.diagnostic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = diagnostic.isEmpty ? item.status.localizedTitle : diagnostic
            return "\(item.name): \(detail)"
        }
        return lines.joined(separator: "\n")
    }
}
