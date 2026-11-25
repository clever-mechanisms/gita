import AppKit
import GitaCore

/// The Pull Requests page's filter bar: state chips with counts (`All`, `Open`, `Review requested`, `Draft`, `Merged`,
/// `Closed`), author and sort menus, and a search field.
@MainActor
final class PullRequestFilterBar: NSView, NSSearchFieldDelegate {
    private static let barHeight: CGFloat = 34
    private static let searchWidth: CGFloat = 170

    let search = NSSearchField()
    var onChange: ((PullRequestFilter) -> Void)?
    private(set) var filter = PullRequestFilter()
    private var chips: [(PullRequestStateFilter, PartsButton)] = []
    private let chipRow = Deck.hstack([], spacing: 4)
    private let authorButton = PartsButton([], background: .hover, accessibility: String(localized: "Filter by author"))
    private let sortButton = PartsButton([], background: .hover, accessibility: String(localized: "Sort pull requests"))
    private let trailingControls: NSStackView
    private var authors: [PullRequestFilter.AuthorCount] = []
    private var viewerLogin: String?
    var isNarrow = false {
        didSet {
            guard isNarrow != oldValue else { return }
            trailingControls.isHidden = isNarrow
            updateChips(counts: lastCounts)
        }
    }
    private var lastCounts: [PullRequestStateFilter: Int] = [:]
    private var searchDebounceTask: DispatchWorkItem?
    /// Coalesces rapid typing in the search field so Auto Layout never rebuilds on every keystroke.
    var searchDebounceInterval: TimeInterval = 0.08

    isolated deinit { searchDebounceTask?.cancel() }

    override init(frame frameRect: NSRect) {
        trailingControls = Deck.hstack([authorButton, sortButton, search], spacing: 6)
        super.init(frame: frameRect)
        buildChips()
        configureTrailing()
        let bar = Deck.hstack([chipRow, Deck.spacer(), trailingControls], spacing: 10)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        Deck.pin(bar, in: self)
        heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true
        setAccessibilityIdentifier("pullRequests.filterBar")
        updateButtons()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func apply(
        filter: PullRequestFilter, counts: [PullRequestStateFilter: Int],
        authors: [PullRequestFilter.AuthorCount], viewerLogin: String?
    ) {
        self.filter = filter
        self.lastCounts = counts
        self.authors = authors
        self.viewerLogin = viewerLogin
        if search.stringValue != filter.query { search.stringValue = filter.query }
        updateChips(counts: counts)
        updateButtons()
    }

    func focusSearch() -> Bool {
        guard !isHidden, !isNarrow, let window else { return false }
        window.makeFirstResponder(search)
        return true
    }

    func controlTextDidChange(_: Notification) {
        let next = search.stringValue
        guard filter.query != next else { return }
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        if next.isEmpty || searchDebounceInterval <= 0 {
            filter.query = next
            onChange?(filter)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.filter.query != next else { return }
                self.filter.query = next
                self.onChange?(self.filter)
            }
        }
        searchDebounceTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + searchDebounceInterval, execute: work)
    }

    private func buildChips() {
        for choice in PullRequestStateFilter.allCases {
            let chip = PartsButton([], background: .hover, accessibility: choice.localizedTitle) { [weak self] in
                self?.chooseState(choice)
            }
            chip.fixedHeight = 22
            chip.horizontalPadding = 7
            chip.spacing = 5
            chip.cornerRadius = 5
            chip.setAccessibilityIdentifier("pullRequests.filter.\(choice.rawValue)")
            chips.append((choice, chip))
            chipRow.addArrangedSubview(chip)
        }
        chipRow.setAccessibilityElement(true)
        chipRow.setAccessibilityRole(.radioGroup)
        chipRow.setAccessibilityLabel(String(localized: "Filter pull requests by status"))
    }

    private func configureTrailing() {
        for button in [authorButton, sortButton] {
            button.fixedHeight = 22
            button.horizontalPadding = 7
            button.cornerRadius = 5
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        authorButton.setAccessibilityIdentifier("pullRequests.authorFilter")
        sortButton.setAccessibilityIdentifier("pullRequests.sort")
        authorButton.menuProvider = { [weak self] in self?.buildAuthorMenu() }
        sortButton.menuProvider = { [weak self] in self?.buildSortMenu() }

        search.placeholderString = String(localized: "Filter")
        search.controlSize = .small
        search.font = Theme.caption
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel(String(localized: "Filter pull requests"))
        search.setAccessibilityIdentifier("pullRequests.searchField")
        search.widthAnchor.constraint(equalToConstant: Self.searchWidth).isActive = true
    }

    private func chooseState(_ choice: PullRequestStateFilter) {
        filter.state = filter.state == choice ? .all : choice
        onChange?(filter)
    }

    private func updateChips(counts: [PullRequestStateFilter: Int]) {
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for (choice, chip) in chips {
            configureChip(chip, for: choice, count: counts[choice] ?? 0, digits: digits)
        }
    }

    private func configureChip(
        _ chip: PartsButton, for choice: PullRequestStateFilter, count: Int, digits: NSFont
    ) {
        let active = filter.state == choice
        let name = choice.localizedTitle
        let textColor = active ? Theme.text : Theme.secondaryText
        var parts: [PartsButton.Part] = []
        if let symbol = Self.symbol(for: choice) {
            parts.append(.symbol(symbol.name, color: symbol.color, size: 10.5))
        }
        if !isNarrow || choice == .all || active {
            parts.append(.text(name, font: active ? Theme.captionEmphasis : Theme.caption, color: textColor))
        }
        parts.append(.text("\(count)", font: digits, color: Theme.secondaryText))
        chip.parts = parts
        chip.isHidden = isChipHidden(choice, count: count, active: active)
        chip.background = active ? .tinted : .hover
        chip.tintFill = Theme.selection
        chip.tintBorder = .clear
        chip.toolTip = "\(name) (\(count))"
        chip.setAccessibilityLabel("\(name), \(count)")
        chip.setAccessibilityValue(active ? String(localized: "selected") : nil)
    }

    private func isChipHidden(_ choice: PullRequestStateFilter, count: Int, active: Bool) -> Bool {
        if active { return false }
        if isNarrow && choice.hidesWhenEmpty { return true }
        return choice.hidesWhenEmpty && count == 0
    }

    private func updateButtons() {
        let activeAuthor = filter.author != nil
        authorButton.parts = [
            .symbol("person", color: activeAuthor ? Theme.accentText : Theme.secondaryText, size: 10.5),
            .text(
                filter.author ?? String(localized: "Author"), font: Theme.caption,
                color: activeAuthor ? Theme.text : Theme.secondaryText),
            .symbol("chevron.down", color: Theme.tertiaryText, size: 8),
        ]
        authorButton.background = activeAuthor ? .selected : .hover
        authorButton.toolTip = String(localized: "Filter by author")

        let customSort = filter.sort != .status
        sortButton.parts = [
            .symbol("arrow.up.arrow.down", color: customSort ? Theme.accentText : Theme.secondaryText, size: 10),
            .text(
                filter.sort.localizedTitle, font: Theme.caption, color: customSort ? Theme.text : Theme.secondaryText),
            .symbol("chevron.down", color: Theme.tertiaryText, size: 8),
        ]
        sortButton.background = customSort ? .selected : .hover
        sortButton.toolTip = String(localized: "Sort pull requests")
    }

    func buildAuthorMenu() -> NSMenu {
        let menu = NSMenu()
        let all = MenuAction(String(localized: "All Authors")) { [weak self] in self?.chooseAuthor(nil) }
        all.state = filter.author == nil ? .on : .off
        menu.addItem(all)
        if let viewer = viewerLogin,
            let own = authors.first(where: { $0.login.caseInsensitiveCompare(viewer) == .orderedSame })
        {
            let mine = MenuAction(String(localized: "Me (\(own.login)) · \(own.count)")) { [weak self] in
                self?.chooseAuthor(own.login)
            }
            mine.state = filter.author?.caseInsensitiveCompare(own.login) == .orderedSame ? .on : .off
            menu.addItem(mine)
        }
        let others = authors.filter { entry in
            viewerLogin.map { entry.login.caseInsensitiveCompare($0) != .orderedSame } ?? true
        }
        if !others.isEmpty {
            menu.addItem(.separator())
            for entry in others {
                let item = MenuAction("\(entry.login) · \(entry.count)") { [weak self] in
                    self?.chooseAuthor(entry.login)
                }
                item.state = filter.author?.caseInsensitiveCompare(entry.login) == .orderedSame ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    func buildSortMenu() -> NSMenu {
        let menu = NSMenu()
        for option in PullRequestSort.allCases {
            let item = MenuAction(option.localizedTitle) { [weak self] in self?.chooseSort(option) }
            item.state = filter.sort == option ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func chooseAuthor(_ login: String?) {
        guard filter.author != login else { return }
        filter.author = login
        onChange?(filter)
    }

    private func chooseSort(_ sort: PullRequestSort) {
        guard filter.sort != sort else { return }
        filter.sort = sort
        onChange?(filter)
    }

    private static func symbol(for choice: PullRequestStateFilter) -> (name: String, color: NSColor)? {
        switch choice {
        case .all: nil
        case .open: ("arrow.triangle.pull", Theme.success)
        case .reviewRequested: ("eye", Theme.needsInputText)
        case .draft: ("pencil.circle", Theme.secondaryText)
        case .merged: ("arrow.triangle.merge", Theme.merged)
        case .closed: ("xmark.circle", Theme.secondaryText)
        }
    }
}
