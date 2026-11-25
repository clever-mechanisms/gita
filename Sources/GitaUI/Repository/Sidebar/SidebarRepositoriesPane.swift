import AppKit
import GitaCore

/// Pinned collapsible `REPOSITORIES` drawer in the sidebar: remembers its collapsed state and height
/// (capped at ≤40% by `RepositorySidebarView`), supports type-to-select and a local `⌘F` filter.
@MainActor
final class SidebarRepositoriesPane: NSView, NSSearchFieldDelegate {
    private enum Metrics {
        static let headerHeight: CGFloat = 26
        static let filterHeight: CGFloat = 22
        static let filterInset: CGFloat = 10
        static let filterGap: CGFloat = 4
        static let listInset: CGFloat = 4
    }

    let list = SidebarPaneList()
    let filter = NSSearchField()
    let header = NSView()
    let toggleButton = NSButton()
    private let disclosure = NSImageView()
    private let titleLabel = Deck.label("", font: TextLines.system(11, weight: .semibold), color: Theme.secondaryText)
    private let countLabel = Deck.label("", font: Theme.caption, color: Theme.tertiaryText)
    lazy var sortButton: PartsButton = {
        let button = PartsButton(
            [.symbol("arrow.up.arrow.down", color: Theme.secondaryText, size: 10.5)], background: .hover,
            accessibility: String(localized: "Sort Repositories"))
        button.fixedHeight = 20
        button.horizontalPadding = 4
        button.cornerRadius = 5
        button.toolTip = String(localized: "Sort Repositories")
        button.setAccessibilityIdentifier("sidebar.repositoriesSort")
        button.menuProvider = { [weak self] in self?.sortMenu?() }
        return button
    }()

    var sortMenu: (() -> NSMenu?)?
    var onCollapseChange: ((Bool) -> Void)?
    var onRebuildRequested: (() -> Void)?

    private let state: SidebarState
    private var input = RepositorySidebarView.Input()
    private var lastQuery = ""
    private(set) var isFilterVisible = false
    private lazy var filterTop = filter.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 0)
    private lazy var filterHeight = filter.heightAnchor.constraint(equalToConstant: 0)
    private lazy var scrollTop = list.scroll.topAnchor.constraint(
        equalTo: filter.bottomAnchor, constant: Metrics.filterGap)

    var rows: [RepositorySidebarView.Row] { list.rows }
    var isCollapsed: Bool { state.repositoriesCollapsed }
    private var query: String { filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(state: SidebarState) {
        self.state = state
        super.init(frame: .zero)
        configureList()
        configureHeader()
        configureFilter()
        layoutViews()
        applyCollapsedState()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    private func configureList() {
        list.configure(
            accessibilityLabel: String(localized: "Repositories"), allowsTypeSelect: true,
            contentInsets: NSEdgeInsets(top: Metrics.listInset, left: 0, bottom: Metrics.listInset, right: 0))
        list.typeSelectString = { row in
            switch row {
            case .repository(let repo, _): repo.name
            case .checkout(let checkout, _, _): checkout.branch
            default: nil
            }
        }
        list.actions.onToggleRepository = { [weak self] repo, expanded in
            guard let self else { return }
            self.state.repositoryExpansion[repo.root.path] = !expanded
            self.onRebuildRequested?()
        }
        list.actions.onSetRepositoryExpanded = { [weak self] repo, expanded in
            guard let self else { return }
            self.state.repositoryExpansion[repo.root.path] = expanded
            self.onRebuildRequested?()
        }
    }

    private func configureHeader() {
        disclosure.setSymbol("chevron.down", size: 9, weight: .semibold, color: Theme.tertiaryText)
        let title = String(localized: "Repositories")
        titleLabel.attributedStringValue = NSAttributedString(
            string: title.localizedUppercase,
            attributes: [
                .font: TextLines.system(11, weight: .semibold), .foregroundColor: Theme.secondaryText, .kern: 0.45,
                .paragraphStyle: Deck.truncatingTail,
            ])
        toggleButton.isBordered = false
        toggleButton.title = ""
        toggleButton.target = self
        toggleButton.action = #selector(toggleCollapsed)
        toggleButton.setAccessibilityLabel(title)
        toggleButton.setAccessibilityIdentifier("sidebar.repositoriesToggle")
    }

    private func configureFilter() {
        filter.placeholderString = String(localized: "Filter repositories…")
        filter.controlSize = .small
        filter.font = Theme.body
        filter.delegate = self
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.sendsSearchStringImmediately = true
        filter.isHidden = true
        filter.setAccessibilityLabel(String(localized: "Filter repositories"))
        filter.setAccessibilityIdentifier("sidebar.repositoriesFilter")
    }

    private func layoutViews() {
        for view in [disclosure, titleLabel, countLabel, toggleButton, sortButton] as [NSView] {
            header.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        for view in [header, filter, list.scroll] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let scrollBottom = list.scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        scrollBottom.priority = .init(999)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            disclosure.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            disclosure.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 5),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sortButton.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 4),
            sortButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            sortButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            toggleButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            toggleButton.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -4),
            toggleButton.topAnchor.constraint(equalTo: header.topAnchor),
            toggleButton.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.filterInset),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.filterInset),
            filterTop, filterHeight,
            list.scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollTop, scrollBottom,
        ])
    }

    func update(_ next: RepositorySidebarView.Input) {
        input = next
        rebuild()
    }

    func rebuild() {
        let count = input.repositories.count > 1 && query.isEmpty ? "\(input.repositories.count)" : ""
        countLabel.stringValue = count
        let next = SidebarRowBuilder(
            input: input, query: "", repositoryExpansion: state.repositoryExpansion,
            groupExpansion: state.groupExpansion, order: state.repositoryOrder,
            key: { WindowAgents.key($0) }
        ).repositoryRows(query: query)
        list.applyRows(next)
    }

    @objc func toggleCollapsed() {
        setCollapsed(!state.repositoriesCollapsed)
    }

    func setCollapsed(_ collapsed: Bool) {
        guard state.repositoriesCollapsed != collapsed else { return }
        if collapsed, isFilterVisible { hideFilter() }
        state.repositoriesCollapsed = collapsed
        applyCollapsedState()
        onCollapseChange?(collapsed)
    }

    private func applyCollapsedState() {
        let collapsed = state.repositoriesCollapsed
        disclosure.setSymbol(
            collapsed ? "chevron.right" : "chevron.down", size: 9, weight: .semibold, color: Theme.tertiaryText)
        toggleButton.setAccessibilityExpanded(!collapsed)
        list.scroll.isHidden = collapsed
        filter.isHidden = collapsed || !isFilterVisible
        scrollTop.constant = collapsed ? 0 : Metrics.filterGap
    }

    func showFilter() {
        if isCollapsed { setCollapsed(false) }
        isFilterVisible = true
        filter.isHidden = false
        filterTop.constant = Metrics.filterGap
        filterHeight.constant = Metrics.filterHeight
        window?.makeFirstResponder(filter)
    }

    func hideFilter() {
        isFilterVisible = false
        if !filter.stringValue.isEmpty {
            filter.stringValue = ""
            filterChanged()
        }
        filter.isHidden = true
        filterTop.constant = 0
        filterHeight.constant = 0
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "f",
            isFocusWithinPane
        else { return super.performKeyEquivalent(with: event) }
        showFilter()
        return true
    }

    private var isFocusWithinPane: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    func controlTextDidChange(_: Notification) { filterChanged() }

    func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        hideFilter()
        window?.makeFirstResponder(list.table)
        return true
    }

    @objc func filterChanged() {
        guard query != lastQuery else { return }
        lastQuery = query
        rebuild()
        list.scrollOffset = -.greatestFiniteMagnitude
    }
}
