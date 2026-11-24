import AppKit
import GitaCore

/// A removable `20 pt` pill inside the history header's filter bar (`(◐ Ana ✕)` or `(⏷ Path: Foo ✕)`).
@MainActor
final class HistoryFilterPillView: NSView {
    private enum Metrics {
        static let height: CGFloat = 20
        static let maxLabelWidth: CGFloat = 130
        static let symbolSize: CGFloat = 10
        static let removeSize: CGFloat = 8.5
    }

    private let modeButton = PartsButton([], background: .none, accessibility: "")
    private let label = Deck.label("", font: Theme.caption, color: Theme.text)
    private let removeButton = PartsButton(
        [.symbol("xmark", color: Theme.secondaryText, size: Metrics.removeSize)],
        background: .none, accessibility: String(localized: "Remove filter"))

    var onToggleMode: (() -> Void)?
    var onRemove: (() -> Void)?

    init(author: HistoryFilters.AuthorFilter) {
        super.init(frame: .zero)
        configureAppearance()
        modeButton.parts = [
            .symbol(
                author.mode.symbol,
                color: author.mode == .filter ? Theme.accentText : Theme.secondaryText,
                size: Metrics.symbolSize)
        ]
        modeButton.setAccessibilityLabel(author.mode.accessibilityDescription)
        modeButton.toolTip = author.mode.accessibilityDescription
        modeButton.setAccessibilityIdentifier("history.filterPill.toggleMode")
        modeButton.onClick = { [weak self] in self?.onToggleMode?() }
        label.stringValue = author.author.name
        label.toolTip =
            author.author.email.isEmpty ? author.author.name : "\(author.author.name) <\(author.author.email)>"
        setAccessibilityIdentifier("history.filterPill.author")
        removeButton.setAccessibilityIdentifier("history.filterPill.removeAuthor")
        buildLayout()
    }

    init(search: HistoryFilters.SearchFilter) {
        super.init(frame: .zero)
        configureAppearance()
        modeButton.parts = [.symbol("line.3.horizontal.decrease", color: Theme.accentText, size: Metrics.symbolSize)]
        modeButton.isEnabled = false
        modeButton.setAccessibilityLabel(search.field.localizedTitle)
        label.stringValue = "\(search.field.localizedTitle): \(search.query)"
        label.toolTip = label.stringValue
        setAccessibilityIdentifier("history.filterPill.search")
        removeButton.setAccessibilityIdentifier("history.filterPill.removeSearch")
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("HistoryFilterPillView is built in code") }

    private func configureAppearance() {
        wantsLayer = true
        layer?.cornerRadius = Metrics.height / 2
        layer?.borderWidth = 1
        updateColors()
        removeButton.onClick = { [weak self] in self?.onRemove?() }
        modeButton.fixedHeight = 16
        modeButton.horizontalPadding = 3
        removeButton.fixedHeight = 16
        removeButton.horizontalPadding = 3
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func buildLayout() {
        let stack = Deck.hstack([modeButton, label, removeButton], spacing: 2)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 3)
        Deck.pin(stack, in: self)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxLabelWidth),
        ])
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.control.cgColor
            layer?.borderColor = Theme.separator.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
}
