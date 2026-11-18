import AppKit

/// The operation bar: what is paused and why, then Review, Resolve Simple, Continue, Skip… and Abort….
@MainActor
final class OperationBarView: NSStackView {
    static let height: CGFloat = 36

    private let label = Style.label("", size: 12, weight: .medium)
    private let continueButton: NSButton
    private let skipButton: NSButton
    private let abortButton: NSButton
    private let simpleButton: NSButton
    var onReview: (() -> Void)?
    var onResolveSimple: (() -> Void)?

    /// `commands` receives Continue, Skip… and Abort…; Review shows the conflicted files.
    init(commands: AnyObject?) {
        continueButton = Style.button(
            String(localized: "Continue"), symbol: "play.fill", target: commands,
            action: #selector(RepositoryCommandResponder.continueOperation))
        skipButton = Style.button(
            String(localized: "Skip…"), symbol: "forward.end", target: commands,
            action: #selector(RepositoryCommandResponder.skipOperation))
        abortButton = Style.button(
            String(localized: "Abort…"), symbol: "xmark", target: commands,
            action: #selector(RepositoryCommandResponder.abortOperation))
        simpleButton = Style.button(
            String(localized: "Resolve Simple"), symbol: "wand.and.stars", target: nil, action: nil)
        super.init(frame: .zero)
        simpleButton.target = self
        simpleButton.action = #selector(simplePressed)
        let review = Style.button(
            String(localized: "Review"), symbol: "square.and.pencil", target: self, action: #selector(reviewPressed))
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for item in [label, space, review, simpleButton, continueButton, skipButton, abortButton] {
            addArrangedSubview(item)
        }
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        label.textColor = Theme.needsInputText
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    @objc private func reviewPressed() { onReview?() }
    @objc private func simplePressed() { onResolveSimple?() }

    func apply(_ state: OperationBarState) {
        isHidden = state.isHidden
        label.stringValue = state.title
        label.toolTip = state.toolTip
        simpleButton.title = state.resolveSimpleTitle
        for (button, spec) in [
            (simpleButton, state.resolveSimple), (continueButton, state.continueButton), (skipButton, state.skip),
            (abortButton, state.abort),
        ] {
            button.isHidden = spec.isHidden
            button.isEnabled = spec.isEnabled
            button.toolTip = spec.toolTip
        }
    }
}
