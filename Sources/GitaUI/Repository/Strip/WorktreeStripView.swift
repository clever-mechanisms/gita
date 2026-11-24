import AppKit
import GitaCore

/// The adaptive strip above the history: hidden (0 pt) when nothing actionable exists beyond the toolbar,
/// else a single 34 pt row of intrinsic chips (Remote update · Agent · Pull request · Checks · Deployment).
@MainActor
final class WorktreeStripView: NSView {
    static let compactHeight: CGFloat = 34
    static let narrowDeployWidth: CGFloat = 900
    private static let horizontalPadding: CGFloat = 10
    private static let chipSpacing: CGFloat = 6

    /// The integration-backed chips. A chip whose integration is off is omitted.
    enum Cell: Int, CaseIterable {
        case agent, pullRequest, checks, deployment

        static func shown(_ defaults: UserDefaults = Preference.store) -> Set<Self> {
            var cells = Set(Self.allCases)
            if !Integration.agents.isEnabled(defaults) { cells.remove(.agent) }
            if !Integration.github.isEnabled(defaults) { cells.subtract([.pullRequest, .checks]) }
            if !Integration.vercel.isEnabled(defaults) { cells.remove(.deployment) }
            return cells
        }
    }

    struct RemoteHint: Equatable {
        var summary: String
        var toolTip: String
    }

    struct Input: Equatable {
        var shown = Set(Cell.allCases)
        var head: String?
        var remoteUpdate: RemoteHint?
        var session: AgentSession?
        /// Other top-level agents and subagents in this checkout besides `session`.
        var otherAgents = 0
        var subagents = 0
        var pullRequest: ProviderItem?
        var canCreatePullRequest = false
        var checks: [ProviderItem] = []
        var deployment: ProviderItem?
        /// On the production branch the chip shows what production serves instead of the branch's preview.
        var production: VercelContext.Production?
        var productionBehind: Int?
        var isProductionBranch = false
        /// The branch's stable preview URL (always its latest deployment) and its unresolved preview comments.
        var branchURL: URL?
        var comments = 0
    }

    var onAgent: ((AgentSession?) -> Void)?
    var onCreatePullRequest: (() -> Void)?
    var onChecks: (() -> Void)?
    var onFetch: (() -> Void)?
    var open: (URL) -> Void = { Deck.open($0) }

    private(set) var input = Input()
    private(set) var mode: StripMode = .hidden
    private var narrowDeploy = false
    private let chipStack = Deck.hstack([], spacing: chipSpacing)
    private var cells: [StripCell] = []
    private let bottomRule = FillView(color: Theme.separator)
    private(set) lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        chipStack.distribution = .gravityAreas
        for view in [chipStack, bottomRule] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            chipStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            chipStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalPadding),
            chipStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomRule.heightAnchor.constraint(equalToConstant: 1),
        ])
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: mode.height) }
    override var isHidden: Bool {
        didSet { updateHeightConstraint() }
    }

    override func layout() {
        let narrow = bounds.width > 0 && bounds.width < Self.narrowDeployWidth
        if narrow != narrowDeploy {
            narrowDeploy = narrow
            reconfigure()
        }
        super.layout()
    }

    override func draw(_: NSRect) {
        if mode.isAttention {
            Theme.needsInput.withAlphaComponent(0.08).setFill()
            bounds.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func update(_ next: Input) {
        guard next != input else { return }
        input = next
        reconfigure()
    }

    /// Rebuilds every chip from the current input (also after the code font or window width changed).
    func reconfigure() {
        let nextMode = StripPresenter.mode(input, narrow: narrowDeploy)
        mode = nextMode
        let chips = nextMode.chips
        while cells.count < chips.count {
            let cell = StripCell()
            cells.append(cell)
            chipStack.addArrangedSubview(cell)
        }
        for (index, cell) in cells.enumerated() {
            guard index < chips.count else {
                cell.isHidden = true
                cell.onClick = nil
                continue
            }
            let content = chips[index]
            cell.isHidden = false
            cell.apply(content)
            let click = content.click
            cell.onClick =
                click == .none
                ? nil
                : { [weak self, weak cell] in
                    if let self, let cell { self.perform(click, from: cell) }
                }
        }
        bottomRule.isHidden = chips.isEmpty
        updateHeightConstraint()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func updateHeightConstraint() {
        heightConstraint.constant = isHidden ? 0 : mode.height
    }

    /// What a chip's click opens.
    func perform(_ click: StripCellContent.Click, from _: NSView) {
        switch click {
        case .none: break
        case .agent(let session): onAgent?(session)
        case .createPullRequest: onCreatePullRequest?()
        case .checks: onChecks?()
        case .fetch: onFetch?()
        case .open(let url): open(url)
        }
    }
}
