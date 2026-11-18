import AppKit
import GitaCore

/// Worktrees & Agents as a right-hand pane of the main window. Every agent session and worktree across repositories:
/// the open repository's group on top, then the others; a state filter (All · Needs input · Working · Done · Idle ·
/// No agent) and a text filter. A row opens in place onto its session (running time, folder, state source) with
/// Show in History and the Open actions.
@MainActor
final class AgentsPaneView: NSView, NSSearchFieldDelegate {
    var onReveal: ((AgentSession) -> Void)?
    var onOpenCheckout: ((URL) -> Void)?
    var onShowInHistory: ((Row) -> Void)?
    var onNewWorktree: (() -> Void)?
    var canCreateWorktree = false { didSet { newWorktree.isEnabled = canCreateWorktree } }

    private(set) var rows: [Row] = []
    private(set) var expanded: String?
    /// The state filter and repository order, shared by every tab's pane.
    let choices: AgentsPaneChoices
    private var filterChips: [(StateFilter, PartsButton)] = []
    private let chipRow = Deck.hstack([], spacing: 4)
    let filter = NSSearchField()
    let list = Deck.vstack([], spacing: 0)
    private let scroll = NSScrollView()
    let emptyLabel = Deck.label(
        String(localized: "No agents or worktrees"), font: Theme.body, color: Theme.secondaryText)
    private lazy var newWorktree = Self.headerButton(
        "plus", size: 13, label: String(localized: "New Worktree…"), action: { [weak self] in self?.onNewWorktree?() })
    private var orderObserver: NSObjectProtocol?
    private lazy var sortButton: PartsButton = {
        let button = Self.headerButton("arrow.up.arrow.down", size: 12, label: String(localized: "Sort Repositories"))
        button.setAccessibilityIdentifier("agents.sort")
        button.menuProvider = { [weak self] in self?.orderMenu() }
        return button
    }()

    init(frame frameRect: NSRect = .zero, choices: AgentsPaneChoices = .shared) {
        self.choices = choices
        super.init(frame: frameRect)
        buildChips()
        layoutPane()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Worktrees & Agents"))
        orderObserver = NotificationCenter.default.addObserver(
            forName: .gitaPreferenceChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard note.userInfo?["key"] as? String == Preference.agentsPaneOrder.rawValue else { return }
            MainActor.assumeIsolated {
                guard let self, !self.rows.isEmpty else { return }
                self.rebuild()
            }
        }
    }
    @available(*, unavailable, message: "The agents pane is built in code")
    required init?(coder _: NSCoder) { fatalError("The agents pane is built in code") }
    isolated deinit {
        if let orderObserver { NotificationCenter.default.removeObserver(orderObserver) }
    }

    private static func headerButton(
        _ symbol: String, size: CGFloat, label: String, action: (() -> Void)? = nil
    ) -> PartsButton {
        let button = PartsButton(
            [.symbol(symbol, color: Theme.secondaryText, size: size)], background: .hover, accessibility: label,
            onClick: action)
        button.fixedHeight = 24
        button.horizontalPadding = 5
        button.toolTip = label
        return button
    }

    func orderMenu() -> NSMenu {
        let menu = NSMenu()
        for (order, title) in [
            (RepositoryListOrder.status, String(localized: "Sort by Status")),
            (.name, String(localized: "Sort by Name")),
        ] {
            // Every tab's pane, this one included, re-sorts on the change notification.
            let item = MenuAction(title) { [choices] in choices.setOrder(order) }
            item.state = order == choices.order ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func buildChips() {
        for choice in StateFilter.choices {
            let chip = PartsButton([], background: .hover, accessibility: "") { [weak self] in
                self?.choose(choice)
            }
            chip.fixedHeight = 22
            chip.horizontalPadding = 7
            chip.spacing = 5
            chip.cornerRadius = 5
            filterChips.append((choice, chip))
            chipRow.addArrangedSubview(chip)
        }
        chipRow.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        chipRow.setAccessibilityElement(true)
        chipRow.setAccessibilityRole(.radioGroup)
        chipRow.setAccessibilityLabel(String(localized: "Agents"))
    }

    /// Picking the chosen filter again goes back to All.
    func choose(_ choice: StateFilter) {
        choices.stateFilter = choices.stateFilter == choice ? .all : choice
        rebuild()
    }

    func update(rows next: [Row]) {
        guard next != rows || list.arrangedSubviews.isEmpty else { return }
        rows = next
        rebuild()
    }

    /// Opens the row for this session or checkout (from history chips, the strip) and scrolls it into view.
    func expand(sessionID: String?) {
        guard let sessionID, let row = rows.first(where: { $0.session?.id == sessionID || $0.id == sessionID }) else {
            return
        }
        expanded = row.id
        if !choices.stateFilter.matches(row) { choices.stateFilter = .all }
        if !filter.stringValue.isEmpty { filter.stringValue = "" }
        rebuild()
        layoutSubtreeIfNeeded()
        if let view = list.arrangedSubviews.first(where: { ($0 as? PaneRowView)?.row.id == row.id }) {
            view.scrollToVisible(view.bounds)
        }
    }
    func controlTextDidChange(_: Notification) { rebuild() }

    func toggle(_ id: String) {
        expanded = expanded == id ? nil : id
        rebuild()
    }

    func rebuild() {
        updateChips()
        let query = filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = AgentsPaneLayout.groups(
            rows, filter: choices.stateFilter, query: query, order: choices.order)
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for group in groups {
            list.addArrangedSubview(
                PaneGroupHeader(title: group.title, count: group.rows.count, isCurrent: group.isCurrent))
            for row in group.rows {
                let view = PaneRowView(row: row, expanded: row.id == expanded)
                view.onToggle = { [weak self] in self?.toggle(row.id) }
                view.owner = self
                list.addArrangedSubview(view)
            }
        }
        for view in list.arrangedSubviews { view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        emptyLabel.isHidden = !groups.isEmpty
    }

    /// Each filter chip's sign and count; a state nothing is in stays out of the way unless it is the chosen one.
    private func updateChips() {
        let sessions = rows.compactMap(\.session)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for (choice, chip) in filterChips {
            let active = choice == choices.stateFilter
            let count = choice.count(in: rows)
            let name = choice.title
            let color = active ? Theme.text : Theme.secondaryText
            let figure = PartsButton.Part.text("\(count)", font: digits, color: color)
            switch choice {
            case .all:
                chip.parts = [
                    .text(name, font: Theme.body, color: color),
                    .text("\(count)", font: digits, color: Theme.secondaryText),
                ]
            case .state(let state):
                chip.parts = Self.signs(state, sessions: sessions) + [figure]
            case .noAgent:
                chip.parts = [.symbol(Deck.worktreeSymbol, color: Theme.secondaryText, size: 11), figure]
            }
            chip.isHidden = count == 0 && !active && choice != .all
            chip.background = active ? .tinted : .hover
            chip.tintFill = Theme.selection
            chip.tintBorder = .clear
            chip.toolTip = name
            chip.setAccessibilityLabel("\(name), \(count)")
            chip.setAccessibilityValue(active ? String(localized: "selected") : nil)
        }
    }

    /// Working shows a turning mark for every agent at work (Claude and Codex side by side); the other states a quiet
    /// symbol (named in the tooltip).
    private static func signs(_ state: AgentState, sessions: [AgentSession]) -> [PartsButton.Part] {
        let marks = state == .working ? workingMarks(sessions) : []
        guard marks.isEmpty else { return marks.map(PartsButton.Part.mark) }
        let color = state == .needsInput ? Theme.needsInputText : Theme.secondaryText
        return [.symbol(Deck.agentStateSymbol(state), color: color, size: 11)]
    }

    /// One working mark per agent tool, in the tools' fixed order so the chip does not reshuffle as sessions change.
    static func workingMarks(_ sessions: [AgentSession]) -> [AgentMarkState] {
        let tools = Set(sessions.filter { $0.state == .working }.map(\.tool))
        return AgentTool.allCases.filter(tools.contains).map { AgentMarkState(tool: $0, state: .working) }
    }

    private func layoutPane() {
        let title = Deck.label(String(localized: "Worktrees & Agents"), font: TextLines.system(13, weight: .semibold))
        title.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        let header = Deck.hstack([title, Deck.spacer(), sortButton, newWorktree], spacing: 2)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 8)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        Deck.pin(list, in: Deck.document(in: scroll))
        // The text filter sits at the bottom, as the sidebar's does.
        filter.placeholderString = String(localized: "Filter")
        filter.controlSize = .small
        filter.font = Theme.body
        filter.delegate = self
        filter.setAccessibilityLabel(String(localized: "Filter worktrees"))
        let footer = NSView()
        footer.addSubview(filter)
        filter.translatesAutoresizingMaskIntoConstraints = false
        let lines = (Deck.separator(), Deck.separator(), Deck.separator())
        let bands: [NSView] = [header, lines.0, chipRow, lines.1, scroll, lines.2, footer]
        for view in bands + [emptyLabel] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        var constraints: [NSLayoutConstraint] = [
            header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: 36),
            lines.0.topAnchor.constraint(equalTo: header.bottomAnchor),
            chipRow.topAnchor.constraint(equalTo: lines.0.bottomAnchor),
            chipRow.heightAnchor.constraint(equalToConstant: 34),
            lines.1.topAnchor.constraint(equalTo: chipRow.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: lines.1.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: lines.2.topAnchor),
            lines.2.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            filter.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            filter.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            filter.topAnchor.constraint(equalTo: footer.topAnchor, constant: 8),
            filter.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -16),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ]
        for band in bands {
            constraints.append(band.leadingAnchor.constraint(equalTo: leadingAnchor))
            constraints.append(
                band === chipRow
                    ? band.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
                    : band.trailingAnchor.constraint(equalTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.sidebar.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
