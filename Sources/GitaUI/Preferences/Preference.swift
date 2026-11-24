import Foundation
import GitaCore

/// Every user setting and its default, in one place. Keys never hold secrets.
/// Existing keys keep their historical names so upgrades keep settings.
enum Preference: String, CaseIterable {
    // General
    case appearance // Int: `AppearanceChoice` raw value
    case theme // String: Theme.Choice raw value ("system" default)
    case editorBundleID // String: "" = first installed of `OpenIn.editorCandidates`
    case terminalBundleID // String: "" = Terminal
    case terminalColors // String: `TerminalColors` raw value — the built-in terminal's light or dark colours
    case terminalPanelShare // Double: the terminal panel's share of the window's height, from the last drag
    case reviewAgent // String: `ReviewAgent` raw value for "Review with …"; "" = first installed
    case reviewSkill // String: `ReviewSkill` raw value the review follows (Matt Pocock's by default)
    case codeFont // String: CodeFont raw value ("system" = SF Mono)
    case interfaceFont // String: InterfaceFont raw value ("system" = SF Pro)

    // Git
    case providerRefresh // Bool: refresh GitHub automatically (the historical key once covered Vercel too)
    case vercelRefresh // Bool: refresh Vercel automatically
    case historyZoomPercent // Int: `HistoryZoom.range`
    case showsHistoryDetails // Bool
    case showsAvatars // Bool: GitHub author pictures (falls back to initials)
    case showsMergeLabel // Bool: show a merge's label ("who · N commits") in history rows
    case mergedCommitsOn // String: "click" | "hover" — what opens a merge's commit list
    case graphLines // String: "rounded" | "angled" (`GraphCell.LineStyle`)
    case commitColor // String: `HistoryTint` for graph lanes ("automatic" keeps a colour per branch)
    case branchColor // String: `HistoryTint` for branch labels ("automatic" is the theme accent)
    case checkedOutColor // String: `HistoryTint` for the checked-out branch ("automatic" is lime)
    case mergeLabelColor // String: `HistoryTint` for a merge's label ("automatic" is purple)
    case squashMergesAsMerges // Bool: draw a squash-merged branch joining its squash commit, like a merge
    // Bool: a merge's row stands for the commits it brought in; they show when it is expanded
    case collapsesMergedCommits
    case pullMode // String: `GitPullMode` raw value — how Pull brings in the upstream's commits
    case mergeMode // String: `GitMergeMode` raw value — the Merge sheet's strategy when it opens
    // Bool: build a missing commit-graph and refresh a stale index where reads are slow (`AppModel+GitCaches`)
    case speedsUpSlowRepositories

    // Integrations: each one off stops its reads and hides what it shows (`Integration`)
    case useGitHub, useVercel // Bool
    case useAgents // Bool: coding-agent detection, the agent marks, the strip's Agent cell and the toolbar's Agents

    // Agents
    case detectClaudeCode, detectCodex, detectOpencode, detectAider, detectGemini, detectCursorAgent // Bool
    case detectAntigravity // Bool
    case useOrca // Bool: merge Orca task titles when Orca is running
    // [String: String]: GitHub repository (`GitHubRemote.sourceID`) → `GitHubAccountStore` entry, logins only
    case githubAccounts

    // Notifications (master switch keeps the historical key)
    case notifications // Bool master
    case notifyPullRequestOpened, notifyReviewRequested, notifyPullRequestMerged
    case notifyChecksFailed, notifyChecksFixed
    case notifyPreviewReady, notifyProductionDeployed
    case notifyVercelAlert // Bool: a new unresolved Vercel alert on a repository's project
    case notifyAgentNeedsInput, notifyAgentFinished
    case silencedRepositories // [String]: resolved repository roots whose notifications are off (a tab's menu)

    // Menu bar
    case menuBarShowsWorkingCount // Bool: number of working agents next to the icon
    case menuBarShowsAttentionDot // Bool: orange dot while the panel's "Needs you" has an item

    // Windows
    case settingsPane // String: last Settings pane (`SettingsPane.rawValue`)
    case authorColors // [String: Int]: author → `Theme.authorColors` index (assigned on first sight)
    case sidebarGroups // [String: Bool]: sidebar group id ("branches", "remote:origin"…) → expanded
    case sidebarRepositories // [String: Bool]: repository root path → expanded in the sidebar's Repositories
    case agentsPaneShown // Bool: the Worktrees & Agents pane on the right of the main window
    case collapsesLeftTabGroups // Bool: a tab group collapses when a tab outside it is chosen
    case groupsWorktreeTabs // Bool: a worktree's tab joins its repository's tab in a group named after the repository
    case workspaceWindows // Bool: a workspace opens in a window of its own instead of taking the window's place
    // String: `RepositoryListOrder` of the sidebar's Repositories ("name" | "recent" | "status")
    case sidebarRepositoryOrder
    case shortcuts // [String: String]: `ShortcutCommand` raw value → `KeyShortcut.storage` ("" = none)
    case filesAsTree // Bool: changed files as a folder tree (else a flat list)
    // Double: Unstaged's share of the Local Changes split height, from the last drag
    case unstagedSplitShare
    case agentsPaneOrder // String: `RepositoryListOrder` of the Worktrees & Agents pane's groups ("status" | "name")

    // App state kept beside the settings
    // [String]: recently opened repository roots, newest first (the first workspace's; see `Workspace.recentKey`)
    case recentRepositories
    case loginItemOfferAnswered // Bool: the Open at Login offer was accepted or dismissed
    case paletteRecents // [String]: ids of the items chosen in the command palette, the latest first

    /// Anything not listed is a Bool that defaults to on.
    var defaultValue: Any { Self.defaults[self] ?? true }

    private static let defaults: [Self: any Sendable] = [
        .appearance: AppearanceChoice.system.rawValue,
        .editorBundleID: "", .terminalBundleID: "", .reviewAgent: "", .terminalColors: TerminalColors.dark.rawValue,
        .terminalPanelShare: TerminalPanelHeight.defaultShare,
        .unstagedSplitShare: FilePaneView.defaultUnstagedShare,
        .reviewSkill: ReviewSkill.default.rawValue,
        .historyZoomPercent: HistoryZoom.actual,
        .theme: "system", .codeFont: "system", .interfaceFont: "system",
        .pullMode: GitPullMode.fastForwardOnly.rawValue, .mergeMode: GitMergeMode.automatic.rawValue,
        .mergedCommitsOn: "click", .graphLines: "rounded",
        .commitColor: "automatic", .branchColor: "automatic", .checkedOutColor: "automatic",
        .mergeLabelColor: "automatic",
        .settingsPane: "general",
        .sidebarRepositoryOrder: "name", .agentsPaneOrder: "status",
        .shortcuts: [String: String](), .authorColors: [String: Int](), .sidebarGroups: [String: Bool](),
        .sidebarRepositories: [String: Bool](), .githubAccounts: [String: String](),
        .recentRepositories: [String](), .silencedRepositories: [String](), .paletteRecents: [String](),
        // macOS permission is requested only when the user turns notifications on.
        .notifications: false,
        .squashMergesAsMerges: false, .agentsPaneShown: false, .collapsesMergedCommits: false,
        .workspaceWindows: false,
        .loginItemOfferAnswered: false,
    ]

    // UserDefaults is documented as thread-safe but not annotated Sendable.
    /// The app's settings domain: development builds keep their own so they never change the installed app's.
    nonisolated(unsafe) static let store: UserDefaults = AppEnvironment.settings(
        development: AppEnvironment.compiledForDevelopment)

    static func registerDefaults(in defaults: UserDefaults = Self.store) {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.defaultValue) }))
    }

    /// The stored value, else the default (also before `registerDefaults`).
    func bool(_ defaults: UserDefaults = Self.store) -> Bool {
        defaults.object(forKey: rawValue) as? Bool ?? (defaultValue as? Bool ?? false)
    }
    func int(_ defaults: UserDefaults = Self.store) -> Int {
        defaults.object(forKey: rawValue) as? Int ?? (defaultValue as? Int ?? 0)
    }
    func string(_ defaults: UserDefaults = Self.store) -> String {
        defaults.string(forKey: rawValue) ?? (defaultValue as? String ?? "")
    }
    func double(_ defaults: UserDefaults = Self.store) -> Double {
        defaults.object(forKey: rawValue) as? Double ?? (defaultValue as? Double ?? 0)
    }
    func strings(_ defaults: UserDefaults = Self.store) -> [String] {
        defaults.stringArray(forKey: rawValue) ?? []
    }
    func set(_ value: Any?, _ defaults: UserDefaults = Self.store) {
        defaults.set(value, forKey: rawValue)
        NotificationCenter.default.post(name: .gitaPreferenceChanged, object: nil, userInfo: ["key": rawValue])
    }

    /// The preference a `.gitaPreferenceChanged` notification names.
    init?(changed notification: Notification) {
        guard let key = notification.userInfo?["key"] as? String else { return nil }
        self.init(rawValue: key)
    }
}

extension Notification.Name {
    /// Posted on the main thread after any `Preference.set`; `userInfo["key"]` is the raw key.
    static let gitaPreferenceChanged = Notification.Name("dev.clevermechanisms.Gita.preferenceChanged")
}
