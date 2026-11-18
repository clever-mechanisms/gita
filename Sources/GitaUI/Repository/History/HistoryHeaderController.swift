import AppKit
import GitaCore

/// The right side of the history header: Stop highlighting, All branches and the history search with its field menu.
@MainActor
final class HistoryHeaderController: NSObject, NSSearchFieldDelegate {
    private static let searchWidth: CGFloat = 190
    /// The search field's share of the accessory, before the links.
    private static let accessoryBase: CGFloat = 200
    private static let linkGap: CGFloat = 10

    let search = NSSearchField()
    let allBranches: PartsButton
    let stopHighlighting: PartsButton
    private weak var header: DeckTableHeaderView?
    var onSearch: ((String) -> Void)?
    var onChooseField: ((HistorySearchField) -> Void)?

    init(header: DeckTableHeaderView, onAllBranches: @escaping () -> Void, onStopHighlighting: @escaping () -> Void) {
        self.header = header
        allBranches = PartsButton.link(String(localized: "All branches"), action: onAllBranches)
        stopHighlighting = PartsButton.link(String(localized: "Stop highlighting"), action: onStopHighlighting)
        super.init()
        search.placeholderString = String(localized: "Search")
        search.delegate = self
        search.controlSize = .small
        search.font = Theme.caption
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = false
        search.toolTip = String(localized: "Search the entire repository history")
        search.setAccessibilityLabel(String(localized: "Search all history"))
        let menu = NSMenu()
        for (index, field) in HistorySearchField.allCases.enumerated() {
            let item = NSMenuItem(title: field.localizedTitle, action: #selector(chooseField(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        (search.cell as? NSSearchFieldCell)?.searchMenuTemplate = menu
        allBranches.setAccessibilityLabel(String(localized: "Show all branches"))
        allBranches.isHidden = true
        stopHighlighting.isHidden = true
        let accessory = Deck.hstack([Deck.spacer(), stopHighlighting, allBranches, search], spacing: 10)
        Deck.pin(accessory, in: header.accessory, insets: NSEdgeInsets(top: 2, left: 0, bottom: 3, right: 0))
        search.widthAnchor.constraint(equalToConstant: Self.searchWidth).isActive = true
        header.accessoryWidth = Self.accessoryBase
    }

    @objc private func searchChanged() { onSearch?(search.stringValue) }

    @objc private func chooseField(_ sender: NSMenuItem) {
        guard HistorySearchField.allCases.indices.contains(sender.tag) else { return }
        onChooseField?(HistorySearchField.allCases[sender.tag])
    }

    func controlTextDidChange(_: Notification) { searchChanged() }

    func show(_ scope: HistoryScopePresenter) {
        allBranches.isHidden = !scope.showsAllBranches
        search.placeholderString = scope.searchPlaceholder
        fitAccessory()
    }

    func showHighlight(_ author: String?) {
        stopHighlighting.isHidden = author == nil
        stopHighlighting.toolTip = author.map { String(localized: "Highlighting \($0)") }
        fitAccessory()
    }

    /// The header's right side: the search field and whichever links are showing, at their own widths.
    private func fitAccessory() {
        let links = [stopHighlighting, allBranches].filter { !$0.isHidden }
        header?.accessoryWidth = Self.accessoryBase + links.reduce(0) { $0 + ceil($1.fittingSize.width) + Self.linkGap }
    }
}
