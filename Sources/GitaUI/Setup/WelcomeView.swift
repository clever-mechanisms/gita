import AppKit
import GitaCore

/// Actionable Welcome Launchpad: left START column (`Open…`, `Clone…`, `New repository…` with live shortcut hints +
/// drop target), right scrollable RECENT column (up to 24 repositories with live filter, lazy `WorkspaceStatusReader`
/// status, and missing-path removal).
@MainActor
final class WelcomeView: NSView {
    static let startColumnWidth: CGFloat = 360
    static let horizontalMargin: CGFloat = 40
    static let topMargin: CGFloat = 32
    static let bottomMargin: CGFloat = 28

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
    let startStack = Deck.vstack([], spacing: 8)
    let recentStack = Deck.vstack([], spacing: 2)
    let recentEmpty = Deck.caption(String(localized: "No recent repositories"))
    let recentCount = Deck.caption("")
    let filterField = NSSearchField()
    let footerStack = Deck.hstack([], spacing: 14)
    let dropZone = WelcomeDropZoneView()
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

    // MARK: Actions & Filtering

    @objc func filterChanged() {
        rebuildRecentRows()
    }

    private func rebuildStartActions() {
        startStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in WelcomePresenter.startActions() {
            var parts: [PartsButton.Part] = [
                .symbol(action.symbol, color: action.kind == .open ? Deck.onAccent : Theme.secondaryText, size: 15),
                .text(
                    action.title, font: TextLines.system(14, weight: .medium),
                    color: action.kind == .open ? Deck.onAccent : Theme.text),
            ]
            if let hint = action.shortcutHint {
                parts.append(
                    .text(
                        hint, font: TextLines.system(12.5, weight: .regular),
                        color: action.kind == .open ? Deck.onAccent.withAlphaComponent(0.85) : Theme.tertiaryText))
            }
            let button = PartsButton(
                parts, background: action.kind == .open ? .accent : .quiet, accessibility: action.title
            ) { [weak self] in
                self?.trigger(action.kind)
            }
            button.contentAlignment = .left
            button.fixedHeight = 44
            button.horizontalPadding = 16
            button.spacing = 10
            button.cornerRadius = 9
            button.setAccessibilityIdentifier("welcome.action.\(action.kind)")
            startStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: startStack.widthAnchor).isActive = true
        }
    }

    private func rebuildFooterHints() {
        footerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for hint in WelcomePresenter.footerHints(defaults: defaults) {
            let text = Style.label("\(hint.shortcut) \(hint.title)", size: 12.5, color: Theme.tertiaryText)
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
        recentCount.stringValue = entries.isEmpty ? "" : "\(entries.count)"
        let visible = WelcomePresenter.filter(entries, query: filterField.stringValue)
        recentEmpty.stringValue =
            entries.isEmpty
            ? String(localized: "No recent repositories") : String(localized: "No matching repositories")
        recentEmpty.isHidden = !visible.isEmpty
        for entry in visible {
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
