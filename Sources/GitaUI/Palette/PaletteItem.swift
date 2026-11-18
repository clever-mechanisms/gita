import AppKit
import GitaCore

/// What the palette finds, in the order its sections show while nothing is typed. Each kind is also a scope (Tab
/// moves between them).
enum PaletteKind: String, CaseIterable {
    case branch, command, pullRequest, workflow, deployment, workspace, repository, commit

    var title: String {
        switch self {
        case .branch: String(localized: "Branches")
        case .command: String(localized: "Commands")
        case .pullRequest: String(localized: "Pull Requests")
        case .workflow: String(localized: "Workflows")
        case .deployment: String(localized: "Deployments")
        case .workspace: String(localized: "Workspaces")
        case .repository: String(localized: "Repositories")
        case .commit: String(localized: "Commits")
        }
    }

    /// The SF Symbol the scope chip and the kind's rows share.
    var symbol: String {
        switch self {
        case .branch: "arrow.triangle.branch"
        case .command: "command"
        case .pullRequest: Section.pullRequests.symbol
        case .workflow: Section.workflows.symbol
        case .deployment: Section.deployments.symbol
        case .workspace: Deck.workspaceSymbol
        case .repository: "folder"
        case .commit: "smallcircle.filled.circle"
        }
    }

    /// How many of the kind show among the others (its own scope shows `scopedLimit`). Commits come only once
    /// something is typed: the history has thousands.
    func sharedLimit(hasQuery: Bool) -> Int {
        switch self {
        case .branch: 5
        case .command: hasQuery ? 6 : 8
        case .commit: hasQuery ? 4 : 0
        default: 4
        }
    }

    static let scopedLimit = 200
}

/// What choosing an item does; the app shell runs it (`AppDelegate.run(_:)`).
enum PaletteAction: Equatable {
    /// A menu item's action, sent as the menu would.
    case menu(NSMenuItem)
    case branch(BranchPaletteEntry)
    /// A pull request, workflow run or deployment, shown on its page.
    case provider(ProviderItem)
    case repository(URL)
    /// Switch to this workspace (`AppDelegate.openWorkspace`).
    case workspace(String)
    case commit(String)
    case settings(SettingsPane)
}

enum PaletteIcon: Equatable {
    case none
    case symbol(String)
    /// A menu item's own image (an app's icon, a provider's mark).
    case image(NSImage)
}

/// One row of the palette.
struct PaletteItem: Equatable, Identifiable {
    /// Stable between showings: the recently chosen items are remembered by it.
    var id: String
    var kind: PaletteKind
    var title: String
    /// Shown after the title and searched too: where the item is, what it belongs to.
    var detail = ""
    /// Searched but not shown.
    var keywords: [String] = []
    var icon = PaletteIcon.none
    /// At the row's end: a shortcut, or when the item last changed.
    var trailing = ""
    var isEnabled = true
    /// Already where it leads (the checked-out branch, the open tab): never the row selected at first.
    var isCurrent = false
    var action: PaletteAction
}

/// An item found by the query: its rank (lower is better) and the characters to highlight.
struct PaletteResult: Equatable {
    var item: PaletteItem
    var score = 0
    var titleRanges: [Range<Int>] = []
    var detailRanges: [Range<Int>] = []
}

/// An item with its texts prepared once, matched at every keystroke.
struct PaletteEntry {
    /// What a match outside the title costs: a word found in the title ranks above the same word in the detail.
    private static let keywordCost = 3
    private static let detailCost = 5
    private static let qualityCost = 10
    /// The worst word decides the rank; the others only break ties.
    private static let worstWeight = 1000
    /// Scores in the same band are as good as each other when sections are ordered.
    private static let bandWidth = 20

    let item: PaletteItem
    private let title: PaletteText
    private let detail: PaletteText
    private let keywords: [PaletteText]

    init(_ item: PaletteItem) {
        self.item = item
        title = PaletteText(item.title)
        detail = PaletteText(item.detail)
        keywords = item.keywords.map(PaletteText.init)
    }

    /// The item as a result when every token is found in its title, detail or keywords; nil otherwise.
    func result(for tokens: [[Character]]) -> PaletteResult? {
        var result = PaletteResult(item: item)
        var worst = 0
        var total = 0
        for token in tokens {
            guard let found = best(token) else { return nil }
            worst = max(worst, found.cost)
            total += found.cost
            result.titleRanges += found.title
            result.detailRanges += found.detail
        }
        result.score = worst * Self.worstWeight + total
        return result
    }

    private struct Found {
        var cost: Int
        var title: [Range<Int>] = []
        var detail: [Range<Int>] = []
    }

    private func best(_ token: [Character]) -> Found? {
        var candidates: [Found] = []
        if let match = title.match(token) {
            candidates.append(Found(cost: match.quality.rawValue * Self.qualityCost, title: match.ranges))
        }
        if let quality = keywords.compactMap({ $0.match(token)?.quality }).min() {
            candidates.append(Found(cost: quality.rawValue * Self.qualityCost + Self.keywordCost))
        }
        if let match = detail.match(token) {
            candidates.append(
                Found(cost: match.quality.rawValue * Self.qualityCost + Self.detailCost, detail: match.ranges))
        }
        return candidates.min { $0.cost < $1.cost }
    }

    /// The coarse strength of a score: the whole title, a whole word, a beginning, inside a word, loose. An item
    /// named exactly what was typed (the Push command) leads its section past one that only contains the word.
    static func band(_ score: Int) -> Int {
        let worst = score / worstWeight
        return worst == 0 ? 0 : 1 + worst / bandWidth
    }
}
