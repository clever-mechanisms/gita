import AppKit
import Combine
import GitaCore

@MainActor
final class ReviewedHunksBarView: NSView {
    var onChange: (() -> Void)?
    private let presenter: ReviewedHunksPresenter
    private let progress = AgentControlPill()
    private let errorLabel = Deck.label("", font: Theme.caption, color: Theme.failure)
    private var buttons: [ReviewedHunkFilterMode: PartsButton] = [:]
    private var observation: AnyCancellable?

    init(presenter: ReviewedHunksPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        let surface = FillView(color: Theme.inset)
        Style.fill(surface, in: self)
        let filters = Deck.hstack([])
        filters.setAccessibilityElement(true)
        filters.setAccessibilityRole(.radioGroup)
        filters.setAccessibilityLabel(String(localized: "Filter hunks"))
        let row = Deck.hstack([progress, errorLabel, Deck.spacer(), filters])
        for mode in ReviewedHunkFilterMode.allCases {
            let button = AgentControlUI.button(Self.title(mode), "review.filter." + mode.rawValue, style: .hover) {
                [weak presenter] in presenter?.setFilter(mode)
            }
            buttons[mode] = button
            button.setAccessibilityRole(.radioButton)
            filters.addArrangedSubview(button)
        }
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        Style.fill(AgentControlUI.column([row, Deck.separator()], spacing: 0), in: surface)
        AgentControlUI.identify(self, "review.bar")
        AgentControlUI.identify(progress, "review.progress")
        observation = presenter.stateChanges.sink { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic view") }

    private static func title(_ mode: ReviewedHunkFilterMode) -> String {
        switch mode {
        case .all: String(localized: "All")
        case .unreviewedOnly: String(localized: "Unreviewed")
        case .reviewedOnly: String(localized: "Reviewed")
        }
    }

    private func render() {
        onChange?()
        let reviewed = presenter.progress?.reviewed ?? 0
        let total = presenter.progress?.total ?? 0
        let colors = Deck.pillColors(reviewed > 0 && reviewed == total ? .head : .branch)
        let mark = AgentControlMark(
            title: String(localized: "\(reviewed)/\(total) reviewed"),
            symbol: "checkmark.circle.fill", color: colors.text)
        progress.update(mark, fill: colors.fill, border: colors.border)
        errorLabel.stringValue = presenter.errorMessage ?? ""
        errorLabel.isHidden = presenter.errorMessage == nil
        for (mode, button) in buttons {
            let selected = mode == presenter.filterMode
            button.background = selected ? .selected : .hover
            button.setAccessibilitySelected(selected)
        }
    }

    static func makeHunkToggleButton(isReviewed: Bool, onToggle: @escaping () -> Void) -> PartsButton {
        let title = isReviewed ? String(localized: "Mark unreviewed") : String(localized: "Mark reviewed")
        let value = isReviewed ? String(localized: "Reviewed") : String(localized: "Unreviewed")
        let color = isReviewed ? Theme.success : Theme.secondaryText
        let button = PartsButton(
            [
                .symbol(isReviewed ? "checkmark.circle.fill" : "circle", color: color, size: 12),
                .text(value, font: Theme.caption, color: color),
            ],
            background: .hover, accessibility: title, onClick: onToggle)
        button.spacing = 4
        button.setAccessibilityValue(value)
        AgentControlUI.identify(button, "review.toggle")
        return button
    }
}
