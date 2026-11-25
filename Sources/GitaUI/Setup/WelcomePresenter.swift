import Foundation
import GitaCore

/// Pure, windowless presentation logic for the Welcome Launchpad (`WelcomeView`).
enum WelcomePresenter {
    static let recentLimit = 24

    enum ActionKind: Equatable, Sendable {
        case open
        case clone
        case initialize
    }

    struct StartAction: Equatable, Sendable {
        var kind: ActionKind
        var title: String
        var symbol: String
        var shortcutHint: String?
    }

    struct FooterHint: Equatable, Sendable {
        var title: String
        var shortcut: String
    }

    struct StatusSummary: Equatable, Sendable {
        var branch: String?
        var changedFiles: Int
        var ahead: Int
        var behind: Int
        var remoteMoved: Bool
        var agentState: AgentState?
        var agentTool: AgentTool?
        var lastUpdated: Date?

        var isClean: Bool { changedFiles == 0 && ahead == 0 && behind == 0 && !remoteMoved }
    }

    enum EntryStatus: Equatable, Sendable {
        case loading
        case ready(StatusSummary)
        case missing
    }

    struct RecentEntry: Equatable, Sendable {
        var path: String
        var url: URL
        var name: String
        var displayPath: String
        var status: EntryStatus
    }

    enum DropOutcome: Equatable, Sendable {
        case ignore
        case openRepository(URL)
        case offerInitialize(URL)
    }

    static func startActions() -> [StartAction] {
        [
            StartAction(
                kind: .open, title: String(localized: "Open…"), symbol: "folder", shortcutHint: "⌘O"),
            StartAction(
                kind: .clone, title: String(localized: "Clone…"), symbol: "arrow.down", shortcutHint: nil),
            StartAction(
                kind: .initialize, title: String(localized: "New repository…"), symbol: "plus",
                shortcutHint: nil),
        ]
    }

    static func footerHints(defaults: UserDefaults = Preference.store) -> [FooterHint] {
        var hints: [FooterHint] = []
        if let palette = ShortcutStore.shortcut(.commandPalette, defaults) {
            hints.append(FooterHint(title: String(localized: "Palette"), shortcut: palette.display))
        }
        if let terminal = ShortcutStore.shortcut(.toggleTerminal, defaults) {
            hints.append(FooterHint(title: String(localized: "Terminal"), shortcut: terminal.display))
        }
        hints.append(FooterHint(title: String(localized: "Settings"), shortcut: "⌘,"))
        return hints
    }

    static func recentEntries(
        paths: [String], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        homeDirectory: String = NSHomeDirectory()
    ) -> [RecentEntry] {
        var seen = Set<String>()
        var result: [RecentEntry] = []
        for rawPath in paths {
            let canonical = RecentRepositories.canonical(rawPath)
            guard seen.insert(canonical).inserted else { continue }
            let url = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            let exists = fileExists(url.path)
            result.append(
                RecentEntry(
                    path: url.path, url: url, name: url.lastPathComponent,
                    displayPath: displayPath(url.path, homeDirectory: homeDirectory),
                    status: exists ? .loading : .missing))
            if result.count == recentLimit { break }
        }
        return result
    }

    static func filter(_ entries: [RecentEntry], query: String) -> [RecentEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            if entry.name.localizedStandardContains(trimmed) || entry.displayPath.localizedStandardContains(trimmed) {
                return true
            }
            if case .ready(let summary) = entry.status, let branch = summary.branch {
                return branch.localizedStandardContains(trimmed)
            }
            return false
        }
    }

    static func statusSummary(
        git: WorkspaceGitStatus, remoteDelta: RemoteDelta?, agent: (state: AgentState, tool: AgentTool)?,
        lastUpdated: Date?
    ) -> StatusSummary {
        StatusSummary(
            branch: git.branch,
            changedFiles: git.changedFiles,
            ahead: git.ahead,
            behind: git.behind,
            remoteMoved: remoteDelta.map { !$0.isEmpty } ?? false,
            agentState: agent?.state,
            agentTool: agent?.tool,
            lastUpdated: lastUpdated)
    }

    static func badgeText(for summary: StatusSummary) -> String {
        var parts: [String] = []
        if summary.changedFiles > 0 { parts.append("●\(summary.changedFiles)") }
        if summary.behind > 0 { parts.append("↓\(summary.behind)") }
        if summary.ahead > 0 { parts.append("↑\(summary.ahead)") }
        if summary.remoteMoved && summary.behind == 0 { parts.append("⇣") }
        if parts.isEmpty { return String(localized: "Clean") }
        return parts.joined(separator: " ")
    }

    @MainActor
    static func relativeDateText(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        return DeckFormat.relative(date, now: now)
    }

    static func displayPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let normalizedHome = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if path == normalizedHome { return "~" }
        if path.hasPrefix(normalizedHome + "/") {
            return "~" + String(path.dropFirst(normalizedHome.count))
        }
        return path
    }

    static func dropOutcome(
        for urls: [URL],
        isDirectory: (URL) -> Bool = { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        },
        isRepository: (URL) -> Bool = { GitDirectoryLocator.locate(checkout: $0) != nil }
    ) -> DropOutcome {
        guard let first = urls.first(where: { $0.isFileURL })?.standardizedFileURL else { return .ignore }
        let directory = isDirectory(first) ? first : first.deletingLastPathComponent()
        guard isDirectory(directory) else { return .ignore }
        return isRepository(directory) ? .openRepository(directory) : .offerInitialize(directory)
    }
}
