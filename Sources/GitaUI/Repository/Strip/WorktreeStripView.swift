import AppKit
import GitaCore

/// The strip above the history: Agent · Branch · Pull request · Checks · Preview deployment,
/// each cell one click to its obvious action (bring the terminal forward, switch branch, open or create the PR,
/// show the checks, open or copy the preview).
@MainActor
final class WorktreeStripView: NSView {
    static let height: CGFloat = 66
    /// Below this width the agent cell takes more of the room.
    private static let narrowWidth: CGFloat = 960
    private static let narrowWeights: [CGFloat] = [1.75, 0.85, 0.85, 0.8, 1.35]
    private static let wideWeights: [CGFloat] = [1.45, 0.9, 0.9, 0.9, 1.6]

    /// The five cells, in order. A cell whose integration is off is not shown; the others share its room.
    enum Cell: Int, CaseIterable {
        case agent, branch, pullRequest, checks, deployment

        /// The cells shown with the integrations as they are switched now.
        static func shown(_ defaults: UserDefaults = Preference.store) -> Set<Self> {
            var cells = Set(Self.allCases)
            if !Integration.agents.isEnabled(defaults) { cells.remove(.agent) }
            if !Integration.github.isEnabled(defaults) { cells.subtract([.pullRequest, .checks]) }
            if !Integration.vercel.isEnabled(defaults) { cells.remove(.deployment) }
            return cells
        }
    }

    struct Input: Equatable {
        /// The cells shown (`Cell.shown`).
        var shown = Set(Cell.allCases)
        var branch: String?
        var head: String?
        var ahead = 0
        var behind = 0
        var hasUpstream = true
        var changedFiles = 0
        var session: AgentSession?
        /// Other top-level agents and subagents in this checkout besides `session`.
        var otherAgents = 0
        var subagents = 0
        var pullRequest: ProviderItem?
        var canCreatePullRequest = false
        var checks: [ProviderItem] = []
        var deployment: ProviderItem?
        var deploymentStatus: String?
        /// On the production branch the cell shows what production serves instead of the branch's preview.
        var production: VercelContext.Production?
        var productionBehind: Int?
        var isProductionBranch = false
        /// The branch's stable preview URL (always its latest deployment) and its unresolved preview comments.
        var branchURL: URL?
        var comments = 0
    }
    var onAgent: ((AgentSession?) -> Void)?
    var onBranch: ((NSView) -> Void)?
    var onCreatePullRequest: (() -> Void)?
    var onChecks: (() -> Void)?
    var onPage: ((Section) -> Void)?
    var open: (URL) -> Void = { Deck.open($0) }
    private(set) var input = Input()
    private let cells = (0..<5).map { _ in StripCell() }
    private var dividers: [NSView] = []
    private let bottomRule = FillView(color: Theme.separator)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for cell in cells { addSubview(cell) }
        dividers = (1..<cells.count).map { _ in
            let line = FillView(color: Theme.separator)
            addSubview(line)
            return line
        }
        addSubview(bottomRule)
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override func layout() {
        super.layout()
        let weights = bounds.width < Self.narrowWidth ? Self.narrowWeights : Self.wideWeights
        let visible = cells.indices.filter { Cell(rawValue: $0).map(input.shown.contains) == true }
        let total = visible.map { weights[$0] }.reduce(0, +)
        var x: CGFloat = 0
        for (index, cell) in cells.enumerated() {
            cell.isHidden = !visible.contains(index)
            if dividers.indices.contains(index) { dividers[index].isHidden = index == visible.last || cell.isHidden }
            guard !cell.isHidden, total > 0 else { continue }
            let width = index == visible.last ? bounds.width - x : floor(bounds.width * weights[index] / total)
            cell.frame = NSRect(x: x, y: 0, width: width, height: bounds.height - 1)
            x += width
            if dividers.indices.contains(index) {
                dividers[index].frame = NSRect(x: x - 1, y: 0, width: 1, height: bounds.height - 1)
            }
        }
        bottomRule.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    func update(_ next: Input) {
        guard next != input else { return }
        if next.shown != input.shown { needsLayout = true }
        input = next
        reconfigure()
    }

    /// Rebuilds every cell from the current input (also after the code font changed).
    func reconfigure() {
        for (cell, content) in zip(cells, WorktreeStripCells.cells(input)) {
            cell.apply(content)
            let click = content.click
            cell.onClick =
                click == .none
                ? nil
                : { [weak self, weak cell] in
                    if let self, let cell { self.perform(click, from: cell) }
                }
            cell.onLink = { [weak self, weak cell] in
                if let self, let cell { self.perform(click, from: cell) }
            }
        }
    }

    /// What a cell's click opens.
    func perform(_ click: StripCellContent.Click, from cell: NSView) {
        switch click {
        case .none: break
        case .agent(let session): onAgent?(session)
        case .branch: onBranch?(cell)
        case .createPullRequest: onCreatePullRequest?()
        case .open(let url): open(url)
        case .checks: onChecks?()
        case .page(let section): onPage?(section)
        }
    }
}
