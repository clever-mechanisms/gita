import AppKit
import GitaCore

/// A provider page: its symbol and title, the provider's status, the active `gh` account picker, Refresh, then the
/// expandable list.
@MainActor
final class ProviderPageView: NSView {
    private static let headerHeight: CGFloat = 44
    private static let iconWidth: CGFloat = 18
    static let addAccountTag = -42

    let list = ProviderDisclosureList()
    var onRefresh: (() -> Void)?
    /// The account picker's choice: a login, or nil for Automatic.
    var onChooseAccount: ((GitHubLogin?) -> Void)?
    /// Launches Terminal with `gh auth login`; tests replace this to avoid opening Terminal.
    var onAddAccount: (() -> Void)?
    private let accountPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var accounts: GitHubAccountPicker?
    private let icon = NSImageView()
    private let title = Deck.label("", font: TextLines.system(15, weight: .semibold))
    private let status = Deck.caption("")
    private let refreshButton: PartsButton
    private let headerBar: NSStackView
    private let headerSpacer = Deck.spacer()
    private(set) var isCompact = false
    private(set) var section: Section?
    private var awaitingAccountRefresh = false
    private var activeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        let refresh = PartsButton.quiet(String(localized: "Refresh"), symbol: "arrow.clockwise") {}
        refreshButton = refresh
        let titleGroup = Deck.hstack([icon, title], spacing: 7)
        headerBar = Deck.hstack([titleGroup, headerSpacer, status, accountPopUp, refresh], spacing: 12)
        super.init(frame: frameRect)
        icon.widthAnchor.constraint(equalToConstant: Self.iconWidth).isActive = true
        refresh.onClick = { [weak self] in self?.onRefresh?() }
        accountPopUp.controlSize = .small
        accountPopUp.target = self
        accountPopUp.action = #selector(accountPicked)
        accountPopUp.isHidden = true
        accountPopUp.setAccessibilityIdentifier("provider.accountPopUp")
        accountPopUp.setAccessibilityLabel(String(localized: "GitHub account"))
        headerBar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        let column = Deck.vstack([headerBar, Deck.separator(), list], spacing: 0)
        Style.fill(column, in: self)
        for row in column.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        headerBar.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
        list.setContentHuggingPriority(.defaultLow, for: .vertical)
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAppDidBecomeActive() }
        }
    }

    isolated deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func update(_ state: ProviderPageState, vercel: VercelContext?) {
        if section != state.section {
            section = state.section
            // The page's symbol before its title, as in the sidebar; Deployments shows Vercel's solid triangle in ink.
            icon.setSymbol(
                state.section.symbol, size: 13, weight: .medium,
                color: state.section == .deployments ? Theme.text : Theme.secondaryText)
        }
        title.stringValue = state.section.localizedTitle
        list.update(items: state.items, vercel: vercel)
        list.emptyMessage = state.emptyMessage
        status.stringValue = state.status
        status.toolTip = state.statusToolTip
        showAccounts(state.accounts)
    }

    func setCompact(_ compact: Bool) {
        guard isCompact != compact else { return }
        isCompact = compact
        title.isHidden = compact
        headerSpacer.isHidden = compact
        status.isHidden = compact
        refreshButton.isHidden = compact
        accountPopUp.isHidden = compact || accounts == nil
        headerBar.edgeInsets =
            compact
            ? NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            : NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        list.isCompact = compact
    }

    private func showAccounts(_ picker: GitHubAccountPicker?) {
        accountPopUp.isHidden = isCompact || picker == nil
        guard picker != accounts else { return }
        accounts = picker
        guard let picker else { return }
        accountPopUp.removeAllItems()
        accountPopUp.addItems(withTitles: picker.titles)
        accountPopUp.menu?.addItem(.separator())
        let addItem = NSMenuItem(
            title: String(localized: "Add account…"), action: nil, keyEquivalent: "")
        addItem.tag = Self.addAccountTag
        accountPopUp.menu?.addItem(addItem)
        accountPopUp.selectItem(at: picker.selectedIndex)
        accountPopUp.toolTip = picker.toolTip
    }

    @objc private func accountPicked() {
        if accountPopUp.selectedItem?.tag == Self.addAccountTag {
            accountPopUp.selectItem(at: accounts?.selectedIndex ?? 0)
            triggerAddAccount()
            return
        }
        guard let accounts, accountPopUp.indexOfSelectedItem != accounts.selectedIndex else { return }
        onChooseAccount?(accounts.login(at: accountPopUp.indexOfSelectedItem))
    }

    func triggerAddAccount() {
        awaitingAccountRefresh = true
        if let onAddAccount {
            onAddAccount()
        } else {
            GitHubAccountLogin.openTerminal()
        }
    }

    func handleAppDidBecomeActive() {
        guard awaitingAccountRefresh else { return }
        awaitingAccountRefresh = false
        guard section != .deployments else { return }
        onRefresh?()
    }
}
