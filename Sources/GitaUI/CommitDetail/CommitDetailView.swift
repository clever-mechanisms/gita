import AppKit
import GitaCore

/// The Commit tab under the history: author header, message and trailers on the left;
/// DEPLOYMENTS (Open ↗ · Copy · Inspect · Logs), the PR card expanded in place, and the commit's checks on the right.
/// Nothing opens a window: Inspect and every check row expand in place.
@MainActor
final class CommitDetailView: NSView {
    struct Input: Equatable {
        var commit: GitCommit?
        var message: String?
        var committer: String?
        var stash: GitStash?
        var signals: [ProviderItem]
        var production: ProviderItem?
        /// Live production, branch preview URLs and comments; `productionBehind` counts commits on `productionBranch`.
        var vercel: VercelContext?
        var productionBehind: Int?
        var productionBranch: String?
        /// Errors, rollout, Agent Runs and alerts of the linked project; `vercelDashboard` is its dashboard page.
        var vercelSignals: VercelSignals?
        var vercelDashboard: URL?
    }
    private enum Metrics {
        static let leftInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        static let emptyInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        static let maximumRight: CGFloat = 470
        static let minimumRight: CGFloat = 300
        static let rightShare: CGFloat = 0.48
        /// Room under the scrolled content so the last line never sits on the window edge.
        static let bottomInset: CGFloat = 16
    }
    var loader: ProviderDetailLoader?
    var onSelectCommit: ((String) -> Void)?
    var onVercelAction: ((VercelActionService.Action, ProviderItem) -> Void)?
    var onRolloutAction: ((VercelActionService.RolloutAction) -> Void)?
    /// Failed-build output (redacted, display only); kept for the shown commit and dropped when it changes.
    var buildLogLoader: ((ProviderItem) async -> VercelBuildLog?)?
    private var buildLogs = BuildLogReads()
    private(set) var input: Input?
    private var expanded = Set<String>()
    private var collapsedPullRequests = Set<String>()
    let left = Deck.vstack([], spacing: 10)
    let right = Deck.vstack([], spacing: 0)
    private let leftScroll = NSScrollView()
    private let rightScroll = NSScrollView()
    private let divider = Deck.separator(vertical: true)
    private lazy var rightWidth = rightScroll.widthAnchor.constraint(equalToConstant: Metrics.maximumRight)
    private let empty = Deck.label(String(localized: "Select a commit"), font: Theme.title, color: Theme.secondaryText)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (scroll, stack, insets) in [(leftScroll, left, Metrics.leftInsets), (rightScroll, right, NSEdgeInsetsZero)]
        {
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            Deck.pin(stack, in: Deck.document(in: scroll), insets: insets)
            addSubview(scroll)
            scroll.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(divider)
        addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leftScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftScroll.topAnchor.constraint(equalTo: topAnchor),
            leftScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomInset),
            divider.leadingAnchor.constraint(equalTo: leftScroll.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor), divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightScroll.topAnchor.constraint(equalTo: topAnchor),
            rightScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomInset), rightWidth,
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(String(localized: "Commit details"))
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("CommitDetailView is built in code") }
    isolated deinit { buildLogs.cancelAll() }

    override func layout() {
        let width = min(Metrics.maximumRight, max(Metrics.minimumRight, floor(bounds.width * Metrics.rightShare)))
        if abs(rightWidth.constant - width) > 0.5 { rightWidth.constant = width }
        super.layout()
    }

    func update(_ next: Input) {
        guard next != input else { return }
        if next.commit?.id != input?.commit?.id || next.stash != input?.stash {
            expanded = []
            collapsedPullRequests = []
            buildLogs.cancelAll()
        }
        input = next
        rebuild()
    }
    /// Expands one item's details and scrolls to it (history status chips).
    func focus(_ item: ProviderItem) {
        if item.kind == .pullRequest { collapsedPullRequests.remove(item.id) } else { expanded.insert(item.id) }
        rebuild()
        DispatchQueue.main.async { [weak self] in self?.scrollToItem(item.id) }
    }
    private func scrollToItem(_ id: String) {
        guard let view = right.arrangedSubviews.first(where: { $0.identifier?.rawValue == id }) else { return }
        view.scrollToVisible(view.bounds)
    }

    private func rebuild() {
        left.arrangedSubviews.forEach { $0.removeFromSuperview() }
        right.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let input, input.commit != nil || input.stash != nil else {
            empty.isHidden = false
            leftScroll.isHidden = true
            rightScroll.isHidden = true
            divider.isHidden = true
            return
        }
        empty.isHidden = true
        leftScroll.isHidden = false
        CommitMessageColumn.views(input, selectCommit: onSelectCommit).forEach(left.addArrangedSubview)
        let hasRight = input.commit != nil
        rightScroll.isHidden = !hasRight
        divider.isHidden = !hasRight
        rightWidth.isActive = hasRight
        if hasRight { providerViews(context(input)).forEach(right.addArrangedSubview) }
        for stack in [left, right] {
            let inset = stack.edgeInsets.left + stack.edgeInsets.right
            for view in stack.arrangedSubviews {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
            }
        }
    }

    private func context(_ input: Input) -> CommitDetailContext {
        CommitDetailContext(
            input: input, loader: loader, expanded: expanded, collapsedPullRequests: collapsedPullRequests,
            toggle: { [weak self] id in self?.toggle(id) },
            togglePullRequest: { [weak self] id in self?.togglePullRequest(id) },
            openLogs: { [weak self] item in self?.openLogs(item) }, selectCommit: onSelectCommit,
            vercelAction: onVercelAction, rolloutAction: onRolloutAction,
            buildLog: { [weak self] item in self?.buildLogState(item) ?? .loading })
    }

    private func providerViews(_ context: CommitDetailContext) -> [NSView] {
        let sections = CommitDetailSections(context.input)
        guard !sections.isEmpty else { return [Self.noProviders()] }
        var views: [NSView] = []
        if sections.showsDeployments {
            views.append(DetailRows.sectionHeader(String(localized: "Deployments")))
            if let live = sections.liveBlock { views.append(ProductionRows.liveBlock(live, context: context)) }
            for item in sections.deployments {
                let model = DeploymentBlockModel(
                    item, input: context.input, showsComments: sections.commentItems.contains(item.id))
                views.append(DeploymentBlockView.make(model, context: context))
            }
            switch sections.productionRow {
            case .serves(let live): views.append(ProductionRows.productionServes(live, context: context))
            case .elsewhere(let item): views.append(ProductionRows.productionElsewhere(item))
            case nil: break
            }
        }
        for item in sections.pullRequests {
            views.append(DetailRows.sectionHeader(String(localized: "Pull request")))
            views.append(ProviderCards.pullRequest(item, context: context))
        }
        if !sections.runs.isEmpty {
            views.append(DetailRows.sectionHeader(String(localized: "Checks")))
            views += sections.runs.map { ProviderCards.run($0, context: context) }
        }
        return views
    }

    private static func noProviders() -> NSView {
        let none = Deck.label(
            String(localized: "No pull request, checks or deployments"), font: Theme.body, color: Theme.secondaryText)
        let wrapper = Deck.vstack([none])
        wrapper.edgeInsets = Metrics.emptyInsets
        return wrapper
    }

    /// The build log of a failed deployment; the first ask starts loading it. A read cancelled by a commit change
    /// answers nil and must not land, hence the token: only the item's current read is kept.
    private func buildLogState(_ item: ProviderItem) -> BuildLogView.State {
        if let log = buildLogs.log(item.id) { return BuildLogView.State(log) }
        guard let buildLogLoader else { return .loading }
        buildLogs.load(item.id) { token in
            Task { [weak self] in
                let log = await buildLogLoader(item)
                guard let self, !Task.isCancelled,
                    self.buildLogs.finish(item.id, token: token, log: log ?? BuildLogView.unavailable)
                else { return }
                self.rebuild()
            }
        }
        return .loading
    }

    private func openLogs(_ item: ProviderItem) {
        guard let loader else { return }
        let commit = input?.commit?.id
        Task { [weak self] in
            let report = await loader(item, false)
            // The commit changed meanwhile: its logs are no longer what the user asked for.
            guard self?.input?.commit?.id == commit else { return }
            guard case .deployment(let detail)? = report?.content else {
                Deck.open(item.url)
                return
            }
            Deck.open(detail.dashboardURL ?? item.url)
        }
    }
    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        rebuild()
    }
    private func togglePullRequest(_ id: String) {
        if collapsedPullRequests.contains(id) {
            collapsedPullRequests.remove(id)
        } else {
            collapsedPullRequests.insert(id)
        }
        rebuild()
    }
}
