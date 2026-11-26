import AppKit
import GitaCore

/// Inline `@@` hunk header bar with Stage/Unstage Hunk and Discard Hunk… actions and VoiceOver metadata.
@MainActor
final class DiffHunkBar: NSView {
    struct Configuration: Equatable {
        var header: String
        var hunkIndex: Int
        var totalHunks: Int
        var showsActions: Bool
        var isStaged: Bool
        var isEnabled: Bool
        var fontSize: CGFloat
    }

    static let height: CGFloat = 28
    private static let tint = NSColor.systemBlue.withAlphaComponent(DiffCell.Metrics.tintAlpha)

    let stageButton = PartsButton([], background: .quiet, accessibility: String(localized: "Stage Hunk"))
    let discardButton = PartsButton([], background: .quiet, accessibility: String(localized: "Discard Hunk…"))

    struct ReviewAction {
        let isReviewed: Bool
        let toggle: () -> Void
    }

    private var reviewToggle: (button: PartsButton, reviewed: Bool)?

    func setReviewAction(_ action: ReviewAction?) {
        if let action, let reviewToggle, reviewToggle.reviewed == action.isReviewed {
            reviewToggle.button.onClick = action.toggle
            actionsStack.isHidden = false
            return
        }
        reviewToggle?.button.removeFromSuperview()
        reviewToggle = nil
        guard let action else { return }
        let button = ReviewedHunksBarView.makeHunkToggleButton(isReviewed: action.isReviewed, onToggle: action.toggle)
        actionsStack.insertArrangedSubview(button, at: 0)
        actionsStack.isHidden = false
        reviewToggle = (button, action.isReviewed)
    }

    var onStage: (() -> Void)?
    var onDiscard: (() -> Void)?
    var trailingInset: CGFloat = 0 {
        didSet {
            if trailingInset != oldValue {
                actionsTrailing?.constant = -8 - trailingInset
            }
        }
    }

    private let headerLabel = Style.label("", size: 11, color: .systemBlue)
    private let actionsStack: NSStackView
    private var actionsTrailing: NSLayoutConstraint?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        actionsStack = Style.stack([stageButton, discardButton], spacing: 6)
        actionsStack.detachesHiddenViews = true
        super.init(frame: frameRect)
        stageButton.fixedHeight = 20
        stageButton.cornerRadius = 5
        stageButton.horizontalPadding = 7
        stageButton.setAccessibilityIdentifier("diff.stageHunk")
        stageButton.onClick = { [weak self] in self?.onStage?() }

        discardButton.fixedHeight = 20
        discardButton.cornerRadius = 5
        discardButton.horizontalPadding = 11
        discardButton.setAccessibilityIdentifier("diff.discardHunk")
        discardButton.onClick = { [weak self] in self?.onDiscard?() }

        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionsStack.setHuggingPriority(.required, for: .horizontal)
        actionsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [headerLabel, actionsStack] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let trailing = actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8 - trailingInset)
        actionsTrailing = trailing
        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -8),
            trailing,
            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("DiffHunkBar is built in code") }

    func configure(_ config: Configuration) {
        headerLabel.stringValue = config.header
        headerLabel.font = TextLines.monospaced(config.fontSize)

        let stageTitle = config.isStaged ? String(localized: "Unstage Hunk") : String(localized: "Stage Hunk")
        let stageSymbol = config.isStaged ? "minus" : "plus"
        stageButton.parts = [
            .symbol(stageSymbol, color: Theme.text, size: 10),
            .text(stageTitle, font: Theme.captionEmphasis, color: Theme.text),
        ]
        stageButton.setAccessibilityLabel(stageTitle)
        stageButton.toolTip = stageTitle
        stageButton.isEnabled = config.isEnabled
        stageButton.isHidden = !config.showsActions

        let discardTitle = String(localized: "Discard Hunk…")
        discardButton.parts = [
            .symbol("arrow.uturn.backward", color: Theme.failure, size: 10),
            .text(discardTitle, font: Theme.captionEmphasis, color: Theme.failure),
        ]
        discardButton.setAccessibilityLabel(discardTitle)
        discardButton.toolTip = discardTitle
        discardButton.isEnabled = config.isEnabled
        discardButton.isHidden = !config.showsActions || config.isStaged

        actionsStack.isHidden = !config.showsActions
        setAccessibilityLabel(
            Self.accessibilityDescription(
                header: config.header, hunkIndex: config.hunkIndex, totalHunks: config.totalHunks))
        setAccessibilityCustomActions(customActions(for: config))
        needsDisplay = true
    }

    private func customActions(for config: Configuration) -> [NSAccessibilityCustomAction] {
        guard config.showsActions, config.isEnabled else { return [] }
        let stageTitle = config.isStaged ? String(localized: "Unstage Hunk") : String(localized: "Stage Hunk")
        var actions = [
            NSAccessibilityCustomAction(name: stageTitle) { [weak self] in
                self?.onStage?()
                return true
            }
        ]
        if !config.isStaged {
            actions.append(
                NSAccessibilityCustomAction(name: String(localized: "Discard Hunk…")) { [weak self] in
                    self?.onDiscard?()
                    return true
                })
        }
        return actions
    }

    /// Parses `@@ -oldStart[,oldCount] +newStart[,newCount] @@` into a VoiceOver summary such as
    /// `"Hunk 2 of 5, lines 58 to 66"`.
    static func accessibilityDescription(header: String, hunkIndex: Int, totalHunks: Int) -> String {
        let ordinal = hunkIndex + 1
        let total = max(ordinal, totalHunks)
        guard let range = parseHunkRange(header) else {
            return String(localized: "Hunk \(ordinal) of \(total)")
        }
        let start = range.newCount > 0 ? range.newStart : range.oldStart
        let count = max(1, range.newCount > 0 ? range.newCount : range.oldCount)
        let end = start + count - 1
        if start == end {
            return String(localized: "Hunk \(ordinal) of \(total), line \(start)")
        }
        return String(localized: "Hunk \(ordinal) of \(total), lines \(start) to \(end)")
    }

    private struct HunkHeaderRange {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
    }

    private static func parseHunkRange(_ header: String) -> HunkHeaderRange? {
        guard header.hasPrefix("@@ ") else { return nil }
        let rest = header.dropFirst(3)
        guard let closing = rest.range(of: " @@") else { return nil }
        let parts = rest[..<closing.lowerBound].split(separator: " ")
        guard parts.count == 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+"),
            let old = parseSide(parts[0].dropFirst()),
            let new = parseSide(parts[1].dropFirst())
        else { return nil }
        return HunkHeaderRange(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count)
    }

    private static func parseSide(_ token: Substring) -> (start: Int, count: Int)? {
        let pieces = token.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = Int(pieces[0]) else { return nil }
        let count = pieces.count > 1 ? Int(pieces[1]) : 1
        guard let count else { return nil }
        return (start, count)
    }

    override func draw(_: NSRect) {
        Self.tint.setFill()
        bounds.fill()
        Theme.separator.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// Interactive gap row allowing the user to expand diff context (`3 -> 10 -> 25 -> Whole file`).
@MainActor
final class DiffContextExpandBar: NSView {
    static let height: CGFloat = 26

    let expandButton = PartsButton(
        [
            .symbol("arrow.down.to.line", color: Deck.link, size: 10),
            .text(String(localized: "Show 20 more lines"), font: Theme.captionEmphasis, color: Deck.link),
        ],
        background: .hover,
        accessibility: String(localized: "Show 20 more lines"))

    var onExpand: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        expandButton.fixedHeight = 20
        expandButton.horizontalPadding = 10
        expandButton.cornerRadius = 5
        expandButton.setAccessibilityIdentifier("diff.expandContext")
        expandButton.onClick = { [weak self] in self?.onExpand?() }
        addSubview(expandButton)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            expandButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("DiffContextExpandBar is built in code") }

    func configure(context: Int) {
        let label =
            context >= 25
            ? String(localized: "Show whole file")
            : String(localized: "Show 20 more lines")
        expandButton.parts = [
            .symbol("arrow.down.to.line", color: Deck.link, size: 10),
            .text(label, font: Theme.captionEmphasis, color: Deck.link),
        ]
        expandButton.setAccessibilityLabel(label)
    }

    override func draw(_: NSRect) {
        Theme.inset.withAlphaComponent(0.75).setFill()
        bounds.fill()
        Theme.separator.withAlphaComponent(0.4).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
