import AppKit
import GitaCore

/// Sleek 36pt operation banner shown above repository content during an active or finished `git bisect` session.
@MainActor
final class BisectBannerView: NSView {
    static let height: CGFloat = 36

    var onGood: (() -> Void)?
    var onBad: (() -> Void)?
    var onSkip: (() -> Void)?
    var onReset: (() -> Void)?
    var onOpenCommit: ((String) -> Void)?

    private let icon = NSImageView()
    private let titleLabel = Deck.label("", font: Theme.captionEmphasis, color: Theme.text)
    private let shaPill = HistoryToolBadgePill(monospaced: true)
    private let subjectLabel = Deck.label("", font: Theme.caption, color: Theme.text)
    private let stepsBadge = HistoryToolBadgePill(monospacedDigits: true)
    private let detailLabel = Deck.caption("")
    private let goodButton: PartsButton
    private let badButton: PartsButton
    private let skipButton: PartsButton
    private let openCommitButton: PartsButton
    private let resetButton: PartsButton
    private let border = Deck.separator()
    private(set) var model = BisectBannerModel(state: .inactive, action: .idle)

    override init(frame frameRect: NSRect) {
        self.goodButton = PartsButton(
            [
                .symbol("checkmark.circle.fill", color: Theme.success, size: 11),
                .text(String(localized: "Good"), font: Theme.captionEmphasis, color: Theme.text),
            ],
            background: .quiet,
            accessibility: String(localized: "Mark commit as good")
        )
        self.badButton = PartsButton(
            [
                .symbol("xmark.circle.fill", color: Theme.failure, size: 11),
                .text(String(localized: "Bad"), font: Theme.captionEmphasis, color: Theme.text),
            ],
            background: .quiet,
            accessibility: String(localized: "Mark commit as bad")
        )
        self.skipButton = PartsButton.quiet(String(localized: "Skip"), symbol: "forward.end") {}
        self.openCommitButton = PartsButton(
            [
                .symbol("arrow.up.right.square", color: Deck.onAccent, size: 11),
                .text(String(localized: "Open Commit"), font: Theme.captionEmphasis, color: Deck.onAccent),
            ],
            background: .accent,
            accessibility: String(localized: "Open culprit commit")
        )
        self.resetButton = PartsButton.quiet(String(localized: "Reset"), symbol: "arrow.uturn.backward") {}
        super.init(frame: frameRect)
        wantsLayer = true
        configureControls()
        buildLayout()
        apply(model)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    /// Binds this banner directly to a `BisectPresenter`.
    func bind(to presenter: BisectPresenter) {
        onGood = { [weak presenter] in presenter?.markGood() }
        onBad = { [weak presenter] in presenter?.markBad() }
        onSkip = { [weak presenter] in presenter?.skip() }
        onReset = { [weak presenter] in presenter?.reset() }
        onOpenCommit = { [weak presenter] _ in presenter?.openCulpritCommit() }
        presenter.onChange = { [weak self] next in self?.apply(next) }
        apply(presenter.bannerModel)
    }

    func apply(_ next: BisectBannerModel) {
        model = next
        isHidden = next.isHidden
        guard !next.isHidden else {
            needsDisplay = true
            return
        }
        let accent = next.isFinished ? Theme.success : Theme.running
        icon.setSymbol(
            next.errorMessage != nil
                ? "exclamationmark.triangle.fill" : (next.isFinished ? "checkmark.seal.fill" : "scope"),
            size: 13,
            color: next.errorMessage != nil ? Theme.failure : accent
        )
        titleLabel.stringValue = next.title
        titleLabel.textColor = next.errorMessage != nil ? Theme.failure : accent

        shaPill.isHidden = next.shortSHA.isEmpty
        if !next.shortSHA.isEmpty {
            shaPill.apply(title: next.shortSHA, color: next.isFinished ? Theme.success : Theme.text)
            shaPill.toolTip = next.commitTooltip
        }
        subjectLabel.stringValue = next.commitSubject
        subjectLabel.toolTip = next.commitTooltip
        subjectLabel.isHidden = next.commitSubject.isEmpty

        if let steps = next.stepsBadgeText {
            stepsBadge.apply(title: steps, color: next.isFinished ? Theme.success : Theme.needsInputText)
            stepsBadge.isHidden = false
        } else {
            stepsBadge.isHidden = true
        }

        let secondary = next.errorMessage ?? next.statusDetail ?? ""
        detailLabel.stringValue = secondary
        detailLabel.toolTip = secondary
        detailLabel.textColor = next.errorMessage != nil ? Theme.failure : Theme.secondaryText
        detailLabel.isHidden = secondary.isEmpty

        updateButtons(for: next)
        setAccessibilityLabel("\(next.title) \(next.shortSHA) \(next.commitSubject)")
        needsDisplay = true
    }

    private func updateButtons(for next: BisectBannerModel) {
        goodButton.parts = [
            .symbol("checkmark.circle.fill", color: Theme.success, size: 11),
            .text(next.goodButtonTitle, font: Theme.captionEmphasis, color: Theme.text),
        ]
        badButton.parts = [
            .symbol("xmark.circle.fill", color: Theme.failure, size: 11),
            .text(next.badButtonTitle, font: Theme.captionEmphasis, color: Theme.text),
        ]
        goodButton.isHidden = !next.showsStepActions
        badButton.isHidden = !next.showsStepActions
        skipButton.isHidden = !next.showsStepActions
        openCommitButton.isHidden = !next.showsOpenCommit
        resetButton.isHidden = !next.showsStepActions && !next.showsOpenCommit
        resetButton.parts = [
            .symbol("arrow.uturn.backward", color: Theme.secondaryText, size: 11),
            .text(
                next.isFinished ? String(localized: "Finish & Reset") : String(localized: "Reset"),
                font: Theme.captionEmphasis,
                color: Theme.text
            ),
        ]
        for button in [goodButton, badButton, skipButton, openCommitButton, resetButton] {
            button.isEnabled = next.canAct
        }
    }

    private func configureControls() {
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [goodButton, badButton, skipButton, openCommitButton, resetButton] {
            button.fixedHeight = 22
            button.horizontalPadding = 8
            button.cornerRadius = 5
            button.spacing = 4
        }
        goodButton.setAccessibilityIdentifier("bisect.good")
        badButton.setAccessibilityIdentifier("bisect.bad")
        skipButton.setAccessibilityIdentifier("bisect.skip")
        openCommitButton.setAccessibilityIdentifier("bisect.openCommit")
        resetButton.setAccessibilityIdentifier("bisect.reset")

        goodButton.onClick = { [weak self] in self?.onGood?() }
        badButton.onClick = { [weak self] in self?.onBad?() }
        skipButton.onClick = { [weak self] in self?.onSkip?() }
        resetButton.onClick = { [weak self] in self?.onReset?() }
        openCommitButton.onClick = { [weak self] in
            guard let id = self?.model.culpritCommitID else { return }
            self?.onOpenCommit?(id)
        }
    }

    private func buildLayout() {
        let row = Deck.hstack(
            [
                icon, titleLabel, shaPill, subjectLabel, stepsBadge, detailLabel,
                Deck.spacer(),
                goodButton, badButton, skipButton, openCommitButton, resetButton,
            ],
            spacing: 8
        )
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        let stack = Deck.vstack([row, border], spacing: 0)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        border.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        Deck.pin(stack, in: self)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard !model.isHidden else {
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        let tint: NSColor =
            if model.errorMessage != nil {
                Theme.failure
            } else if model.isFinished {
                Theme.success
            } else {
                Theme.running
            }
        layer?.backgroundColor = tint.withAlphaComponent(0.11).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
