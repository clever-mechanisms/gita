import AppKit
import GitaCore

/// The pinned history filter bar: active filter pills, `[⑂ Scope ▾]`, `[👤 Author ▾]`,
/// and the history search field with its field menu.
@MainActor
final class HistoryHeaderController: NSObject, NSSearchFieldDelegate {
    private static let searchWidth: CGFloat = 160
    private static let controlHeight: CGFloat = 20
    private static let controlGap: CGFloat = 6

    let search = NSSearchField()
    let scopeButton: PartsButton
    let authorButton: PartsButton
    private let pillsStack = Deck.hstack([], spacing: 4)
    let filterBar = ThemedBackgroundView()

    var onSearch: ((String) -> Void)?
    var onChooseField: ((HistorySearchField) -> Void)?
    var onAllBranches: () -> Void
    var onStopHighlighting: () -> Void
    var onSelectCurrentBranch: (() -> Void)?
    var onSelectBranch: ((GitReference) -> Void)?
    var onSelectAuthor: ((CommitAuthor) -> Void)?
    var onOpenAuthorTab: ((CommitAuthor) -> Void)?
    var onToggleAuthorMode: (() -> Void)?
    var onClearSearch: (() -> Void)?
    /// Injectable modifier flags so tests can verify `⌥`-click without fabricating system events.
    var currentModifiers: () -> NSEvent.ModifierFlags = { NSApp.currentEvent?.modifierFlags ?? [] }

    var availableBranches: [GitReference] = []
    var currentBranchName: String?
    var authorChoices: [CommitAuthor] = []
    var meAuthor: CommitAuthor?
    private(set) var currentFilters = HistoryFilters()

    init(onAllBranches: @escaping () -> Void, onStopHighlighting: @escaping () -> Void) {
        self.onAllBranches = onAllBranches
        self.onStopHighlighting = onStopHighlighting
        scopeButton = PartsButton([], background: .hover, accessibility: String(localized: "History scope"))
        authorButton = PartsButton([], background: .hover, accessibility: String(localized: "Filter by author"))
        super.init()
        configureControls()
        let accessory = Deck.hstack(
            [Deck.spacer(), pillsStack, scopeButton, authorButton, search], spacing: Self.controlGap)
        Deck.pin(accessory, in: filterBar, insets: NSEdgeInsets(top: 2, left: 0, bottom: 3, right: 8))
        search.widthAnchor.constraint(equalToConstant: Self.searchWidth).isActive = true
    }

    private func configureControls() {
        for button in [scopeButton, authorButton] {
            button.fixedHeight = Self.controlHeight
            button.horizontalPadding = 6
            button.cornerRadius = 5
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        scopeButton.setAccessibilityIdentifier("history.scopeButton")
        authorButton.setAccessibilityIdentifier("history.authorButton")
        scopeButton.onClick = { [weak self] in self?.presentScopeMenu() }
        authorButton.onClick = { [weak self] in self?.presentAuthorMenu() }
        pillsStack.detachesHiddenViews = true
        pillsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        search.placeholderString = String(localized: "Search")
        search.delegate = self
        search.controlSize = .small
        search.font = Theme.caption
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = false
        search.toolTip = String(localized: "Search the entire repository history")
        search.setAccessibilityLabel(String(localized: "Search all history"))
        search.setAccessibilityIdentifier("history.searchField")
        let menu = NSMenu()
        for (index, field) in HistorySearchField.allCases.enumerated() {
            let item = NSMenuItem(title: field.localizedTitle, action: #selector(chooseField(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        (search.cell as? NSSearchFieldCell)?.searchMenuTemplate = menu
        updateScopeButton(for: .all)
        updateAuthorButton(compact: false)
    }

    @objc private func searchChanged() { onSearch?(search.stringValue) }

    @objc private func chooseField(_ sender: NSMenuItem) {
        guard HistorySearchField.allCases.indices.contains(sender.tag) else { return }
        onChooseField?(HistorySearchField.allCases[sender.tag])
    }

    func controlTextDidChange(_: Notification) { searchChanged() }

    func show(_ scope: HistoryScopePresenter) {
        search.placeholderString = scope.searchPlaceholder
        currentFilters = scope.historyFilters
        updateScopeButton(for: scope.historyFilters.scope)
        rebuildPills(scope.historyFilters.pills)
        updateAuthorButton(compact: !scope.historyFilters.pills.isEmpty)
    }

    func showHighlight(_ author: String?) {
        if let author {
            let existing = currentFilters.author?.author ?? CommitAuthor(name: author, email: "")
            currentFilters.author = HistoryFilters.AuthorFilter(author: existing, mode: .highlight)
        } else if currentFilters.author?.mode == .highlight {
            currentFilters.author = nil
        }
        rebuildPills(currentFilters.pills)
        updateAuthorButton(compact: !currentFilters.pills.isEmpty)
    }

    private func updateScopeButton(for scope: HistoryFilters.Scope) {
        let isFiltered = scope != .all
        let color = isFiltered ? Theme.accentText : Theme.secondaryText
        scopeButton.parts = [
            .symbol("arrow.triangle.branch", color: color, size: 10),
            .text(scope.title, font: Theme.caption, color: isFiltered ? Theme.text : Theme.secondaryText),
            .symbol("chevron.down", color: Theme.tertiaryText, size: 8),
        ]
        scopeButton.background = isFiltered ? .selected : .hover
        scopeButton.toolTip = String(localized: "Scope: \(scope.title)")
    }

    private func updateAuthorButton(compact: Bool) {
        let active = currentFilters.author != nil
        let color = active ? Theme.accentText : Theme.secondaryText
        var parts: [PartsButton.Part] = [.symbol("person", color: color, size: 10.5)]
        if !compact {
            parts.append(.text(String(localized: "Author"), font: Theme.caption, color: Theme.secondaryText))
        }
        parts.append(.symbol("chevron.down", color: Theme.tertiaryText, size: 8))
        authorButton.parts = parts
        authorButton.toolTip = String(localized: "Filter or highlight by author (⌥-click opens tab)")
    }

    private func rebuildPills(_ pills: [HistoryFilters.Pill]) {
        pillsStack.arrangedSubviews.forEach {
            pillsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for pill in pills {
            let view: HistoryFilterPillView
            switch pill {
            case .author(let filter):
                view = HistoryFilterPillView(author: filter)
                view.onToggleMode = { [weak self] in self?.onToggleAuthorMode?() }
                view.onRemove = { [weak self] in self?.onStopHighlighting() }
            case .search(let filter):
                view = HistoryFilterPillView(search: filter)
                view.onRemove = { [weak self] in self?.onClearSearch?() }
            }
            pillsStack.addArrangedSubview(view)
        }
        pillsStack.isHidden = pills.isEmpty
    }

    func buildScopeMenu() -> NSMenu {
        let menu = NSMenu()
        let allItem = MenuAction(String(localized: "All Branches"), symbol: "point.3.connected.trianglepath.dotted") {
            [weak self] in self?.onAllBranches()
        }
        allItem.state = currentFilters.scope == .all ? .on : .off
        menu.addItem(allItem)

        if let branch = currentBranchName {
            let currentItem = MenuAction(
                String(localized: "Current Branch (\(branch))"), symbol: "arrow.triangle.branch"
            ) { [weak self] in self?.onSelectCurrentBranch?() }
            if case .currentBranch = currentFilters.scope { currentItem.state = .on }
            menu.addItem(currentItem)
        }

        let branches = availableBranches.filter { $0.kind == .branch }
        if !branches.isEmpty {
            menu.addItem(.separator())
            for branch in branches {
                let item = MenuAction(branch.name, symbol: branch.isCurrent ? "checkmark" : nil) { [weak self] in
                    self?.onSelectBranch?(branch)
                }
                if case .reference(let selected) = currentFilters.scope, selected.fullName == branch.fullName {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }
        return menu
    }

    func buildAuthorMenu() -> NSMenu {
        let menu = NSMenu()
        if let me = meAuthor {
            let item = MenuAction(String(localized: "Me (\(me.name))"), symbol: "person.crop.circle") { [weak self] in
                self?.chooseAuthor(me)
            }
            if currentFilters.author?.author == me { item.state = .on }
            menu.addItem(item)
        }
        let others = authorChoices.filter { $0 != meAuthor }
        if !others.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for author in others {
                let item = MenuAction(author.name, symbol: nil) { [weak self] in self?.chooseAuthor(author) }
                if currentFilters.author?.author == author { item.state = .on }
                menu.addItem(item)
            }
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No authors"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        if currentFilters.author != nil {
            menu.addItem(.separator())
            menu.addItem(
                MenuAction(String(localized: "Clear Author Filter"), symbol: "xmark") { [weak self] in
                    self?.onStopHighlighting()
                })
        }
        return menu
    }

    func chooseAuthor(_ author: CommitAuthor) {
        chooseAuthor(author, optionPressed: currentModifiers().contains(.option))
    }

    func chooseAuthor(_ author: CommitAuthor, optionPressed: Bool) {
        if optionPressed {
            onOpenAuthorTab?(author)
        } else {
            onSelectAuthor?(author)
        }
    }

    private func presentScopeMenu() {
        let menu = buildScopeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: scopeButton.bounds.height + 2), in: scopeButton)
    }

    private func presentAuthorMenu() {
        let menu = buildAuthorMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: authorButton.bounds.height + 2), in: authorButton)
    }
}
