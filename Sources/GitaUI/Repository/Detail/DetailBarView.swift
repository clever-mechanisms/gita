import AppKit

/// The bar above the detail pane: Commit · Changes · File Tree, then the parent choice, Apply stash and the SHA.
@MainActor
final class DetailBarView: NSView {
    static let height: CGFloat = 33
    private static let buttonHeight: CGFloat = 22
    private static let parentSHALength = 7

    var onSelectTab: ((DetailTab) -> Void)?
    var onChooseParent: ((Int) -> Void)?
    var onApplyStash: (() -> Void)?

    private var tabButtons: [DetailTab: PartsButton] = [:]
    private let tabStack = Deck.hstack([], spacing: 4)
    private let label = Deck.label("", font: Theme.bodyEmphasis)
    let parentChoice = NSPopUpButton()
    let applyStash = Style.button(
        String(localized: "Apply stash"), symbol: "arrow.uturn.backward", target: nil, action: nil)
    private let sha = PartsButton([], background: .hover, accessibility: String(localized: "Copy SHA"))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyStash.target = self
        applyStash.action = #selector(applyStashPressed)
        applyStash.isHidden = true
        parentChoice.controlSize = .small
        parentChoice.target = self
        parentChoice.action = #selector(parentChanged)
        parentChoice.setAccessibilityLabel(String(localized: "Compare with parent"))
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for tab in DetailTab.allCases {
            let button = PartsButton(
                [.text(tab.title, font: Theme.body, color: Theme.secondaryText)], background: .none,
                accessibility: tab.title
            ) { [weak self] in self?.onSelectTab?(tab) }
            button.fixedHeight = Self.buttonHeight
            button.horizontalPadding = 12
            button.cornerRadius = 5
            button.toolTip = [ShortcutCommand.commitTab, .changesTab, .fileTreeTab][tab.rawValue].toolTip
            tabButtons[tab] = button
            tabStack.addArrangedSubview(button)
        }
        sha.fixedHeight = Self.buttonHeight
        sha.horizontalPadding = 6
        let header = Deck.hstack([tabStack, label, Deck.spacer(), parentChoice, applyStash, sha], spacing: 8)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let bar = RowView()
        bar.bottomSeparator = Theme.separator
        bar.hoverEnabled = false
        Deck.pin(header, in: bar, insets: NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0))
        Deck.pin(bar, in: self)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    @objc private func applyStashPressed() { onApplyStash?() }
    @objc private func parentChanged() { onChooseParent?(parentChoice.indexOfSelectedItem) }

    func apply(_ state: DetailBarState) {
        tabStack.isHidden = !state.showsTabs
        tabButtons[.tree]?.isHidden = !state.showsTreeTab
        for (tab, button) in tabButtons {
            let active = tab == state.tab
            button.parts = [.text(tab.title, font: Theme.body, color: active ? Theme.text : Theme.secondaryText)]
            button.background = active ? .selected : .hover
            button.setAccessibilityValue(active ? String(localized: "selected") : nil)
        }
        label.isHidden = state.label == nil
        label.stringValue = state.label ?? ""
        parentChoice.isHidden = !state.showsParentChoice
        guard let full = state.sha, let short = state.shortSHA else {
            sha.isHidden = true
            return
        }
        sha.parts = [.text(short, font: TextLines.monospaced(11.5), color: Theme.secondaryText)]
        sha.onClick = { Deck.copy(full) }
        sha.toolTip = String(localized: "Copy SHA")
        sha.setAccessibilityLabel(String(localized: "Copy SHA \(short)"))
        sha.isHidden = false
    }

    /// One item per parent, the compared one selected.
    func showParents(_ parents: [String], comparing base: String?) {
        parentChoice.removeAllItems()
        for (index, parent) in parents.enumerated() {
            parentChoice.addItem(
                withTitle: String(localized: "Parent \(index + 1) · \(parent.prefix(Self.parentSHALength))"))
        }
        parentChoice.selectItem(at: parents.firstIndex(of: base ?? "") ?? 0)
    }

    func showStash(_ shown: Bool, enabled: Bool) {
        applyStash.isHidden = !shown
        applyStash.isEnabled = enabled
    }
}
