import AppKit
import GitaCore

/// A provider page: its symbol and title, the provider's status, Refresh, then the expandable list.
@MainActor
final class ProviderPageView: NSView {
    private static let headerHeight: CGFloat = 44
    private static let iconWidth: CGFloat = 18

    let list = ProviderDisclosureList()
    var onRefresh: (() -> Void)?
    /// The account picker's choice: a login, or nil for Automatic.
    var onChooseAccount: ((GitHubLogin?) -> Void)?
    private let accountPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var accounts: GitHubAccountPicker?
    private let icon = NSImageView()
    private let title = Deck.label("", font: TextLines.system(15, weight: .semibold))
    private let status = Deck.caption("")
    private(set) var section: Section?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.widthAnchor.constraint(equalToConstant: Self.iconWidth).isActive = true
        let titleGroup = Deck.hstack([icon, title], spacing: 7)
        let refresh = PartsButton.quiet(String(localized: "Refresh"), symbol: "arrow.clockwise") { [weak self] in
            self?.onRefresh?()
        }
        accountPopUp.controlSize = .small
        accountPopUp.target = self
        accountPopUp.action = #selector(accountPicked)
        accountPopUp.isHidden = true
        accountPopUp.setAccessibilityLabel(String(localized: "GitHub account"))
        let bar = Deck.hstack([titleGroup, Deck.spacer(), status, accountPopUp, refresh], spacing: 12)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        let column = Deck.vstack([bar, Deck.separator(), list], spacing: 0)
        Style.fill(column, in: self)
        for row in column.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        bar.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
        list.setContentHuggingPriority(.defaultLow, for: .vertical)
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

    private func showAccounts(_ picker: GitHubAccountPicker?) {
        accountPopUp.isHidden = picker == nil
        guard picker != accounts else { return }
        accounts = picker
        guard let picker else { return }
        accountPopUp.removeAllItems()
        accountPopUp.addItems(withTitles: picker.titles)
        accountPopUp.selectItem(at: picker.selectedIndex)
        accountPopUp.toolTip = picker.toolTip
    }

    @objc private func accountPicked() {
        guard let accounts, accountPopUp.indexOfSelectedItem != accounts.selectedIndex else { return }
        onChooseAccount?(accounts.login(at: accountPopUp.indexOfSelectedItem))
    }
}
