import AppKit
import GitaCore

/// Actionable Welcome Launchpad: left START column (`Open…`, `Clone…`, `New repository…` with live shortcut hints +
/// drop target), right RECENT column (up to 8 repositories with lazy `WorkspaceStatusReader` status and missing-path
/// removal).
@MainActor
final class WelcomeView: NSView {
    private static let maxContentWidth: CGFloat = 820
    private static let startColumnWidth: CGFloat = 330

    var defaults: UserDefaults = Preference.store
    var onOpen: (() -> Void)?
    var onClone: (() -> Void)?
    var onInitialize: (() -> Void)?
    var onOpenRepository: ((URL) -> Void)?
    var onOfferInitialize: ((URL) -> Void)?
    var onRemoveRecent: ((String) -> Void)?

    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var isDirectory: (URL) -> Bool = {
        (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
    var isRepository: (URL) -> Bool = { GitDirectoryLocator.locate(checkout: $0) != nil }
    var statusReader: @Sendable (URL) async throws -> WorkspaceGitStatus = {
        try await WorkspaceStatusReader.read(root: $0)
    }
    var remoteDeltaProvider: (URL) -> RemoteDelta? = { RemoteMonitor.shared.state(for: $0).last }
    var agentProvider: (URL) -> (state: AgentState, tool: AgentTool)? = { url in
        guard let crowd = WindowAgents.crowd(WindowAgents.shared.sessions(repository: url, worktreePaths: [])) else {
            return nil
        }
        return (crowd.state, crowd.lead.tool)
    }
    var lastUpdatedProvider: (URL) -> Date? = { url in
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private(set) var entries: [WelcomePresenter.RecentEntry] = []
    private var readTasks: [String: Task<Void, Never>] = [:]
    private var recentPaths: [String] = []
    private let startStack = Deck.vstack([], spacing: 10)
    private let recentStack = Deck.vstack([], spacing: 4)
    private let recentEmpty = Deck.caption(String(localized: "No recent repositories"))
    private let footerStack = Deck.hstack([], spacing: 14)
    private let dropZone = WelcomeDropZoneView()
    private var preferenceObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        buildLayout()
        refreshHints()
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .gitaPreferenceChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard Preference(changed: note) == .shortcuts else { return }
            MainActor.assumeIsolated { self?.refreshHints() }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("WelcomeView is built in code") }

    isolated deinit {
        for task in readTasks.values { task.cancel() }
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden { cancelReads() } else if window != nil, !recentPaths.isEmpty { reload(paths: recentPaths) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelReads()
        } else if !isHidden {
            reload(paths: recentPaths)
        }
    }

    func reload(paths: [String]) {
        recentPaths = paths
        cancelReads()
        entries = WelcomePresenter.recentEntries(paths: paths, fileExists: fileExists)
        rebuildRecentRows()
        guard window != nil, !isHidden else { return }
        startLazyReads()
    }

    func cancelReads() {
        for task in readTasks.values { task.cancel() }
        readTasks.removeAll()
    }

    func refreshHints() {
        rebuildStartActions()
        rebuildFooterHints()
    }

    // MARK: Drag & Drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = droppedURLs(from: sender.draggingPasteboard)
        let accepted = !urls.isEmpty
        dropZone.isHighlighted = accepted
        return accepted ? .copy : []
    }

    override func draggingExited(_: (any NSDraggingInfo)?) {
        dropZone.isHighlighted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropZone.isHighlighted = false
        return handleDroppedURLs(droppedURLs(from: sender.draggingPasteboard))
    }

    @discardableResult
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        switch WelcomePresenter.dropOutcome(for: urls, isDirectory: isDirectory, isRepository: isRepository) {
        case .ignore:
            return false
        case .openRepository(let url):
            onOpenRepository?(url)
            return true
        case .offerInitialize(let url):
            onOfferInitialize?(url)
            return true
        }
    }

    private func droppedURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let string = item.string(forType: .fileURL),
                let url = URL(string: string), url.isFileURL
            else { return nil }
            return url
        }
    }

    // MARK: Layout

    private func buildLayout() {
        let title = Style.label("Gitā", size: RepositoryLayout.welcomeTitleSize, weight: .semibold, color: Theme.text)
        let subtitle = Deck.caption(String(localized: "Native Git history, PRs, deploys & agents."))
        let startHeader = Deck.sectionTitle(String(localized: "Start"))
        let leftColumn = Deck.vstack([startHeader, startStack, dropZone, footerStack], spacing: 14)
        leftColumn.alignment = .leading
        leftColumn.widthAnchor.constraint(equalToConstant: Self.startColumnWidth).isActive = true
        dropZone.widthAnchor.constraint(equalTo: leftColumn.widthAnchor).isActive = true

        let recentCard = buildRecentCard()
        let columns = Deck.hstack([leftColumn, recentCard], spacing: RepositoryLayout.welcomeSpacing)
        columns.alignment = .top
        let root = Deck.vstack([title, subtitle, columns], spacing: 10)
        root.alignment = .leading
        root.setCustomSpacing(20, after: subtitle)
        addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.centerXAnchor.constraint(equalTo: centerXAnchor),
            root.centerYAnchor.constraint(equalTo: centerYAnchor),
            root.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            root.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxContentWidth),
            recentCard.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
    }

    private func buildRecentCard() -> NSView {
        let card = FillView(color: Theme.inset)
        card.cornerRadius = 10
        card.borderColor = Theme.separator
        let header = Deck.hstack(
            [Deck.sectionTitle(String(localized: "Recent Repositories")), Deck.spacer()], spacing: 8)
        recentEmpty.alignment = .center
        let stack = Deck.vstack([header, Deck.separator(), recentStack, recentEmpty], spacing: 8)
        stack.alignment = .leading
        Deck.pin(stack, in: card, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return card
    }

    private func rebuildStartActions() {
        startStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in WelcomePresenter.startActions() {
            var parts: [PartsButton.Part] = [
                .symbol(action.symbol, color: action.kind == .open ? Deck.onAccent : Theme.secondaryText, size: 12),
                .text(
                    action.title, font: Theme.bodyEmphasis,
                    color: action.kind == .open ? Deck.onAccent : Theme.text),
            ]
            if let hint = action.shortcutHint {
                parts.append(
                    .text(
                        hint, font: Theme.caption,
                        color: action.kind == .open ? Deck.onAccent.withAlphaComponent(0.85) : Theme.tertiaryText))
            }
            let button = PartsButton(
                parts, background: action.kind == .open ? .accent : .quiet, accessibility: action.title
            ) { [weak self] in
                self?.trigger(action.kind)
            }
            button.fixedHeight = 30
            button.horizontalPadding = 12
            button.cornerRadius = 7
            button.setAccessibilityIdentifier("welcome.action.\(action.kind)")
            startStack.addArrangedSubview(button)
        }
    }

    private func rebuildFooterHints() {
        footerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for hint in WelcomePresenter.footerHints(defaults: defaults) {
            let text = Deck.caption("\(hint.shortcut) \(hint.title)")
            text.textColor = Theme.tertiaryText
            footerStack.addArrangedSubview(text)
        }
    }

    private func trigger(_ kind: WelcomePresenter.ActionKind) {
        switch kind {
        case .open: onOpen?()
        case .clone: onClone?()
        case .initialize: onInitialize?()
        }
    }

    // MARK: Lazy Status Reads

    private func startLazyReads() {
        for entry in entries where entry.status == .loading {
            let url = entry.url
            let path = entry.path
            let reader = statusReader
            readTasks[path] = Task { [weak self] in
                do {
                    let git = try await reader(url)
                    guard let self, !Task.isCancelled else { return }
                    let summary = WelcomePresenter.statusSummary(
                        git: git, remoteDelta: self.remoteDeltaProvider(url),
                        agent: self.agentProvider(url), lastUpdated: self.lastUpdatedProvider(url))
                    self.applyStatus(.ready(summary), for: path)
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    if !self.fileExists(path) {
                        self.applyStatus(.missing, for: path)
                    } else {
                        let empty = WelcomePresenter.StatusSummary(
                            branch: nil, changedFiles: 0, ahead: 0, behind: 0, remoteMoved: false,
                            agentState: nil, agentTool: nil, lastUpdated: self.lastUpdatedProvider(url))
                        self.applyStatus(.ready(empty), for: path)
                    }
                }
            }
        }
    }

    private func applyStatus(_ status: WelcomePresenter.EntryStatus, for path: String) {
        readTasks[path] = nil
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return }
        entries[index].status = status
        rebuildRecentRows()
    }

    private func rebuildRecentRows() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        recentEmpty.isHidden = !entries.isEmpty
        for entry in entries {
            let row = WelcomeRecentRow(
                entry: entry,
                onOpen: { [weak self] in
                    self?.onOpenRepository?(entry.url)
                },
                onRemove: { [weak self] in
                    self?.onRemoveRecent?(entry.path)
                })
            recentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
        }
    }
}

@MainActor
private final class WelcomeDropZoneView: NSView {
    var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = Deck.caption(String(localized: "Drop a folder here to open it"))
        label.alignment = .center
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("WelcomeDropZoneView is built in code") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        let dash: [CGFloat] = [5, 4]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.lineWidth = isHighlighted ? 1.5 : 1
        (isHighlighted ? Theme.accent : Theme.separator).setStroke()
        if isHighlighted {
            Theme.accent.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        path.stroke()
    }
}

@MainActor
private final class WelcomeRecentRow: RowView {
    init(entry: WelcomePresenter.RecentEntry, onOpen: @escaping () -> Void, onRemove: @escaping () -> Void) {
        super.init(frame: .zero)
        let title = Deck.label(entry.name, font: Theme.bodyEmphasis)
        let subtitle = Deck.caption(entry.displayPath)
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var topItems: [NSView] = [title]
        var bottomItems: [NSView] = [subtitle]
        var rightItems: [NSView] = []
        switch entry.status {
        case .loading:
            rightItems.append(Deck.caption("…"))
        case .missing:
            onClick = nil
            let missing = Deck.label(String(localized: "⚠ Missing"), font: Theme.captionEmphasis, color: Theme.failure)
            let remove = PartsButton.link(String(localized: "Remove from list"), size: 11, action: onRemove)
            rightItems.append(contentsOf: [missing, remove])
        case .ready(let summary):
            onClick = onOpen
            if let branch = summary.branch, !branch.isEmpty {
                let branchLabel = Deck.label(branch, font: Theme.mono, color: Theme.secondaryText)
                branchLabel.lineBreakMode = .byTruncatingTail
                topItems.append(branchLabel)
            }
            if let tool = summary.agentTool, let state = summary.agentState {
                let mark = AgentMarkView(side: 12)
                mark.tool = tool
                mark.state = state
                bottomItems.append(mark)
            }
            if let dateText = WelcomePresenter.relativeDateText(summary.lastUpdated) {
                bottomItems.append(Deck.caption(dateText))
            }
            let badgeColor = summary.isClean ? Theme.success : Theme.needsInput
            let badgeText = WelcomePresenter.badgeText(for: summary)
            rightItems.append(Deck.label(badgeText, font: Theme.captionEmphasis, color: badgeColor))
        }
        let topRow = Deck.hstack(topItems + [Deck.spacer()], spacing: 6)
        let bottomRow = Deck.hstack(bottomItems + [Deck.spacer()], spacing: 6)
        let left = Deck.vstack([topRow, bottomRow], spacing: 2)
        let row = Deck.hstack([left, Deck.spacer()] + rightItems, spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        Deck.pin(row, in: self)
        setAccessibilityLabel(entry.name)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("WelcomeRecentRow is built in code") }
}
