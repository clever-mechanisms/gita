import AppKit
import Combine
import GitaCore

@MainActor
final class ReviewedHunksBarView: NSView {
    private let presenter: ReviewedHunksPresenter
    private let progress = AgentControlPill()
    private let errorLabel = Deck.label("", font: Theme.caption, color: Theme.failure)
    private lazy var toggleButton = Self.hunkToggleButton(isReviewed: false) { [weak self] in
        self?.toggleNextHunk()
    }
    private lazy var clearButton = AgentControlUI.button(
        String(localized: "Clear"), "review.clear", style: .hover
    ) { [weak self] in self?.clearReviewed() }
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
        let row = Deck.hstack([progress, toggleButton, clearButton, errorLabel, Deck.spacer(), filters])
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
        let state = presenter.progress
        let reviewed = state?.reviewed ?? 0
        let total = state?.total ?? 0
        let complete = total > 0 && state?.isComplete == true
        let remaining = state?.remaining ?? 0
        let colors = Deck.pillColors(complete ? .head : .branch)
        let mark = AgentControlMark(
            title: String(localized: "\(reviewed)/\(total) reviewed"),
            symbol: "checkmark.circle.fill", color: colors.text)
        progress.update(mark, fill: colors.fill, border: colors.border)
        progress.toolTip =
            remaining == 0
            ? String(localized: "All hunks reviewed")
            : String(localized: "\(remaining) unreviewed hunks remaining")
        let visibleCount = presenter.visibleHunkIndices(for: presenter.activeHashes).count
        toggleButton.isEnabled = visibleCount > 0 || !presenter.activeHashes.isEmpty
        clearButton.isEnabled = reviewed > 0
        errorLabel.stringValue = presenter.errorMessage ?? ""
        errorLabel.isHidden = presenter.errorMessage == nil
        for (mode, button) in buttons {
            let selected = mode == presenter.filterMode
            button.background = selected ? .selected : .hover
            button.setAccessibilitySelected(selected)
        }
    }

    private func toggleNextHunk() {
        guard let path = presenter.activePath, !presenter.activeHashes.isEmpty else { return }
        let target = presenter.activeHashes.first { !presenter.isReviewed($0) } ?? presenter.activeHashes[0]
        presenter.toggle(hash: target, filePath: path)
    }

    private func clearReviewed() {
        if let path = presenter.activePath {
            presenter.clearFile(path)
        } else {
            presenter.clearAll()
        }
    }

    static func hunkToggleButton(isReviewed: Bool, onToggle: @escaping () -> Void) -> NSControl {
        makeHunkToggleButton(isReviewed: isReviewed, onToggle: onToggle)
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
