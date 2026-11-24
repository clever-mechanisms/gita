import AppKit
import GitaCore

/// The menu bar panel, an inbox: "Needs you" and its count with Open Gita · Refresh · ••• at the top, then one list
/// (what needs the user, the agents, the workspaces) that scrolls inside a content-fitted panel, and a footer that
/// opens a repository, makes a workspace or turns the list into the latest activity.
@MainActor
final class MenuPanelController: NSViewController {
    private let actions: MenuPanelActions
    private(set) var page = PanelPage.inbox
    private(set) var state = MenuPanelState()
    private var expanded = Set<String>()
    let list = PanelListView()
    private let scroll = NSScrollView()
    let caption = NSTextField(labelWithString: "")
    private let problemIcon = NSImageView()
    let problemLabel = NSTextField(labelWithString: "")
    private lazy var backButton = PanelIconButton(
        symbol: "chevron.left", label: String(localized: "Back"), identifier: "back", target: self,
        action: #selector(goBack))
    private lazy var refreshButton = PanelIconButton(
        symbol: "arrow.clockwise", label: String(localized: "Refresh"), identifier: "refresh", target: self,
        action: #selector(refresh))
    private lazy var moreButton = PanelIconButton(
        symbol: "ellipsis", label: String(localized: "More"), identifier: "more", target: self,
        action: #selector(showMore))
    private lazy var activityButton = footerButton(
        String(localized: "Activity ›"), style: .subtle, action: .showActivity, identifier: "activity")
    private let problem = PanelProblemBand()
    private let footer = PanelFooterView()
    private lazy var problemHeight = problem.heightAnchor.constraint(equalToConstant: 0)
    private lazy var listHeight = scroll.heightAnchor.constraint(equalToConstant: 100)
    /// Called when the content height changes so the hosting window can resize under the status item.
    var onSizeChange: ((NSSize) -> Void)?
    /// Opens a web page; replaceable so tests never launch a browser.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Puts text on the pasteboard; replaceable so tests never touch the user's clipboard.
    var copyText: (String) -> Void = { Deck.copy($0) }

    static let headerHeight: CGFloat = 38, footerHeight: CGFloat = 34, problemLineHeight: CGFloat = 24
    private static let inset: CGFloat = 14, listBottom: CGFloat = 4

    init(actions: MenuPanelActions) {
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable, message: "The menu panel is built in code")
    required init?(coder _: NSCoder) { fatalError("The menu panel is built in code") }

    override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 300))
        root.setAccessibilityIdentifier("panel")
        view = root
        let header = makeHeader()
        configureList()
        configureProblem()
        let buttons = makeFooter()
        for child in [header, scroll, problem, footer] {
            root.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        activateConstraints(root: root, header: header, footerButtons: buttons)
        rebuild()
    }

    private func makeHeader() -> NSView {
        caption.setAccessibilityIdentifier("panel.caption")
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let open = PanelIconButton(
            symbol: "macwindow", label: String(localized: "Open Gitā"), identifier: "open", target: self,
            action: #selector(openApp))
        let header = NSStackView(views: [backButton, caption, NSView(), open, refreshButton, moreButton])
        header.orientation = .horizontal
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 0, left: Self.inset, bottom: 0, right: 8)
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        return header
    }

    private func configureList() {
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.listBottom, right: 0)
        list.onAction = { [weak self] action in self?.perform(action) }
    }

    private func configureProblem() {
        problemIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        problemIcon.contentTintColor = Theme.needsInputText
        problemIcon.setAccessibilityElement(false)
        problemLabel.font = Theme.caption
        problemLabel.textColor = Theme.needsInputText
        problemLabel.lineBreakMode = .byTruncatingTail
        problemLabel.setAccessibilityIdentifier("panel.problem")
        problemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        problem.configure(icon: problemIcon, label: problemLabel, inset: Self.inset)
    }

    /// Open Repository… and New Workspace… at the leading edge, Activity › at the trailing one.
    private func makeFooter() -> NSStackView {
        let open = footerButton(
            String(localized: "Open Repository…"), symbol: "plus", action: .openRepository,
            identifier: "openRepository")
        let new = footerButton(
            String(localized: "New Workspace…"), symbol: "plus", action: .newWorkspace, identifier: "newWorkspace")
        let buttons = NSStackView(views: [open, new, NSView(), activityButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        footer.addSubview(buttons)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        return buttons
    }

    private func footerButton(
        _ title: String, symbol: String? = nil, style: PanelChip.Style = .link, action: PanelAction,
        identifier: String
    ) -> PanelChipButton {
        let chip = PanelChip(title: title, symbol: symbol, style: style, action: action, label: title)
        let button = PanelChipButton(chip)
        button.onPress = { [weak self] in self?.perform(action) }
        button.setAccessibilityIdentifier("panel." + identifier)
        return button
    }

    private func activateConstraints(root: NSView, header: NSView, footerButtons: NSView) {
        var constraints: [NSLayoutConstraint] = [
            root.widthAnchor.constraint(equalToConstant: Theme.panelWidth),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor), listHeight,
            problem.topAnchor.constraint(equalTo: scroll.bottomAnchor), problemHeight,
            footer.topAnchor.constraint(equalTo: problem.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            problemIcon.widthAnchor.constraint(equalToConstant: 12),
            footerButtons.topAnchor.constraint(equalTo: footer.topAnchor, constant: 1),
            footerButtons.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            footerButtons.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerButtons.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
        ]
        for band in [header, scroll, problem, footer] {
            constraints.append(band.leadingAnchor.constraint(equalTo: root.leadingAnchor))
            constraints.append(band.trailingAnchor.constraint(equalTo: root.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: State

    func update(_ next: MenuPanelState) {
        _ = view
        guard next != state else { return }
        state = next
        rebuild()
    }

    /// Turns the list into the other page, from its top.
    func show(_ next: PanelPage) {
        guard next != page else { return }
        page = next
        list.resetSelection()
        rebuild()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Esc and the back button: the inbox again. False on the inbox itself, where Esc closes the panel.
    @discardableResult func back() -> Bool {
        guard page != .inbox else { return false }
        show(.inbox)
        return true
    }
    @objc private func goBack() { back() }

    func makeListFirstResponder() { view.window?.makeFirstResponder(list) }

    private func rebuild() {
        let now = Date()
        list.set(PanelRowBuilder(state: state, expanded: expanded, now: now).rows(page), width: Theme.panelWidth)
        caption.attributedStringValue = Self.caption(page, needing: state.attention.count)
        backButton.isHidden = page == .inbox
        activityButton.isHidden = page == .activity
        refreshButton.isEnabled = !state.isRefreshing
        refreshButton.toolTip = Self.refreshText(state, now: now)
        let displayProblem = state.problem.map {
            state.problemDetail ?? MenuPanelState.Problem(text: $0, toolTip: $0, repository: nil, provider: nil)
        }
        problemLabel.stringValue = displayProblem?.text ?? ""
        problemLabel.toolTip = displayProblem?.toolTip
        problem.toolTip = displayProblem?.toolTip
        problem.setAccessibilityLabel(displayProblem?.text ?? "")
        problem.setAccessibilityHelp(displayProblem?.toolTip)
        if let repository = displayProblem?.repository {
            let provider = displayProblem?.provider ?? .github
            problem.onPress = { [weak self] in self?.perform(.showProviderPage(repository, provider)) }
        } else {
            problem.onPress = nil
        }
        problemHeight.constant = displayProblem == nil ? 0 : Self.problemLineHeight
        problem.isHidden = displayProblem == nil
        fit()
    }

    /// "NEEDS YOU 3" in the attention colour while something does; "ACTIVITY" on the other page.
    static func caption(_ page: PanelPage, needing count: Int) -> NSAttributedString {
        switch page {
        case .inbox:
            PanelRowView.caption(
                String(localized: "Needs you"), count: count > 0 ? "\(count)" : nil,
                color: count > 0 ? Theme.needsInputText : Theme.secondaryText)
        case .activity: PanelRowView.caption(String(localized: "Activity"), count: nil, color: Theme.secondaryText)
        }
    }

    /// The Refresh button's tooltip: "Refreshing…", "Refresh · Checked 14:02" today, else with the date; "Refresh"
    /// before the first check.
    static func refreshText(_ state: MenuPanelState, now: Date, calendar: Calendar = .current) -> String {
        if state.isRefreshing { return String(localized: "Refreshing…") }
        guard let checked = state.checkedAt else { return String(localized: "Refresh") }
        let time =
            calendar.isDate(checked, inSameDayAs: now)
            ? checked.formatted(date: .omitted, time: .shortened)
            : checked.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return String(localized: "Refresh · Checked \(time)")
    }

    private func fit() {
        let screen =
            view.window?.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame.height ?? 800
        let fixed = Self.headerHeight + problemHeight.constant + Self.footerHeight
        let maximum = max(160, min(620, visible - 24 - fixed))
        listHeight.constant = min(maximum, max(44, list.contentHeight + Self.listBottom))
        let size = NSSize(width: Theme.panelWidth, height: fixed + listHeight.constant)
        preferredContentSize = size
        if view.frame.size != size {
            view.setFrameSize(size)
            onSizeChange?(size)
        }
    }

    // MARK: Actions

    private func perform(_ action: PanelAction) {
        switch action {
        case .openURL(let url): if let url = Deck.safeWebURL(url) { openURL(url) }
        case .copy(let text): copyText(text)
        case .toggle(let id):
            if expanded.remove(id) == nil { expanded.insert(id) }
            rebuild()
        case .showActivity: show(.activity)
        case .showRepository, .showProviderPage, .showTab, .push, .reveal, .openRepository, .openWorkspace,
            .newWorkspace:
            ask(action)
        }
    }

    /// What the panel cannot do itself goes to the app.
    private func ask(_ action: PanelAction) {
        switch action {
        case .showRepository(let url): _ = actions.showRepository(url)
        case .showProviderPage(let url, let provider): actions.showProviderPage(url, provider)
        case .showTab(let url, let workspace): actions.showTab(url, workspace)
        case .push(let url): actions.push(url)
        case .reveal(let id): if let session = state.sessions.first(where: { $0.id == id }) { actions.reveal(session) }
        case .openRepository: actions.openRepository()
        case .openWorkspace(let id): actions.openWorkspace(id)
        case .newWorkspace: actions.newWorkspace()
        case .openURL, .copy, .toggle, .showActivity: break
        }
    }

    @objc private func openApp() { actions.openApp() }
    @objc private func refresh() {
        guard !state.isRefreshing else { return }
        actions.refresh()
    }
    @objc private func showMore() {
        moreMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY + 4), in: moreButton)
    }
    /// ••• : Settings… and Quit Gita.
    func moreMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = NSMenuItem(
            title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.target = self
        let quit = NSMenuItem(title: String(localized: "Quit Gitā"), action: #selector(quitApp), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quit.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quit)
        return menu
    }
    @objc private func openSettings() { actions.settings() }
    @objc private func quitApp() { actions.quit() }

    /// ⌘, Settings · ⌘Q Quit · ⌘R Refresh · ⌘O Open Gita · ⌘N New Workspace · ⌘1…⌘9 the nth workspace, while the
    /// panel has focus.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            let key = event.charactersIgnoringModifiers
        else { return false }
        switch key {
        case ",": actions.settings()
        case "q": actions.quit()
        case "r": refresh()
        case "o": actions.openApp()
        case "n": actions.newWorkspace()
        default:
            // ⌘1 is the first workspace listed: the one in front.
            guard let number = Int(key), state.workspaces.indices.contains(number - 1) else { return false }
            actions.openWorkspace(state.workspaces[number - 1].id)
        }
        return true
    }
}

@MainActor
private final class PanelProblemBand: NSView {
    private let stack = NSStackView()
    private var isHovering = false
    private var isPressed = false
    var onPress: (() -> Void)? {
        didSet {
            setAccessibilityRole(onPress == nil ? .group : .button)
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
            if onPress == nil {
                isHovering = false
                isPressed = false
            }
            needsDisplay = true
        }
    }

    func configure(icon: NSImageView, label: NSTextField, inset: CGFloat) {
        stack.setViews([icon, label], in: .leading)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityIdentifier("panel.problem.band")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        return onPress != nil ? self : super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        HoverTracking.update(self, enabled: onPress != nil)
    }

    override func resetCursorRects() {
        if onPress != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with _: NSEvent) {
        guard onPress != nil else { return }
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovering = false
        isPressed = false
        needsDisplay = true
    }

    override func mouseDown(with _: NSEvent) {
        guard onPress != nil else { return }
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let shouldFire = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        needsDisplay = true
        if shouldFire { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    override func draw(_ _: NSRect) {
        guard isHovering || isPressed, onPress != nil else { return }
        Theme.control.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 5, yRadius: 5).fill()
    }
}
