import AppKit
import GitaCore

/// Local Changes' docked composer: subject with 50-char counter, expandable multi-line description, inline
/// published-amend warning banner, recent-messages menu, and split Commit button.
@MainActor
final class CommitFooterView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    enum Metrics {
        static let subjectHeight: CGFloat = 28
        static let bodyHeight: CGFloat = 62
        static let composerSpacing: CGFloat = 6
        static let actionHeight: CGFloat = 24
        static let padding = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
    }

    let field = NSTextField()
    let bodyView = NSTextView()
    let countLabel = Deck.caption("")
    let commitButton = PartsButton(
        [
            .symbol("checkmark", color: .white, size: 11),
            .text(String(localized: "Commit"), font: Theme.bodyEmphasis, color: .white),
        ],
        background: .accent, accessibility: String(localized: "Commit"))
    let commitMenuButton = PartsButton(
        [.symbol("chevron.down", color: .white, size: 9)], background: .accent,
        accessibility: String(localized: "Commit options"))
    let recentButton = PartsButton(
        [
            .symbol("clock.arrow.circlepath", color: Theme.secondaryText, size: 11),
            .symbol("chevron.down", color: Theme.tertiaryText, size: 8),
        ],
        background: .hover, accessibility: String(localized: "Recent commit messages"))
    let descriptionButton = PartsButton(
        [.symbol("text.alignleft", color: Theme.secondaryText, size: 11)], background: .hover,
        accessibility: String(localized: "Add description"))
    let signingRow = CommitSigningSettingsRow()
    let assistController = CommitMessageAssistController()
    let bannerBox = FillView(color: Theme.needsInput.withAlphaComponent(0.12))
    let bannerLabel = Deck.wrapping("", font: Theme.caption, color: Theme.needsInputText)

    private let composerBox = FillView(color: Theme.window)
    private let bodySeparator = Deck.separator()
    private let bodyScroll = NSScrollView()
    private let bodyPlaceholder = Deck.label(
        String(localized: "Description"), font: Theme.body, color: Theme.tertiaryText)
    private lazy var bodyHeightConstraint = bodyScroll.heightAnchor.constraint(equalToConstant: 0)
    private lazy var fallbackUndoManager = UndoManager()
    private var isUpdatingText = false
    private var isDescriptionFocused = false
    private(set) var isDescriptionExpanded = false

    var lastActionsState = CommitActionsState(
        .init(
            hasSnapshot: false, hasDraft: false, isDraftCurrent: false, hasOperation: false,
            hasConflicts: false, isMutating: false, stagedCount: 0, hasHead: false, mode: .commit,
            amendCommitID: nil, upstreamName: nil, message: ""))
    var recentMessages: [RecentCommitMessage] = []
    var lastUnsentDraft: String?

    var onCommit: (() -> Void)?
    var onCommitAndPush: (() -> Void)?
    var onAmend: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    var onChange: ((String) -> Void)?
    var onFillRecent: ((String) -> Void)?
    var onEndEditing: ((String) -> Void)?
    var onWillOpenRecents: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureActionControls()
        configureRecentControls()
        configureBanner()
        configureComposer()
        layoutFooter()
        refreshComposerUI(animated: false)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    private func configureComposer() {
        composerBox.cornerRadius = 6
        composerBox.borderColor = Theme.separator
        configureSubject()
        configureBody()
    }

    private func configureSubject() {
        field.placeholderString = String(localized: "Commit subject")
        field.font = Theme.body
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel(String(localized: "Commit subject"))
        field.setAccessibilityIdentifier("changes.commitMessage")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right
        countLabel.toolTip = String(localized: "Recommended subject length: 50 characters")
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setAccessibilityIdentifier("changes.subjectCharacterCount")
    }

    private func configureBody() {
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        bodyScroll.documentView = bodyView
        bodySeparator.isHidden = true
        bodyView.isRichText = false
        bodyView.allowsUndo = true
        bodyView.font = Theme.body
        bodyView.textColor = Theme.text
        bodyView.insertionPointColor = Theme.text
        bodyView.drawsBackground = false
        bodyView.textContainerInset = NSSize(width: 4, height: 5)
        bodyView.isAutomaticQuoteSubstitutionEnabled = false
        bodyView.isAutomaticDashSubstitutionEnabled = false
        bodyView.isAutomaticTextReplacementEnabled = false
        bodyView.autoresizingMask = [.width]
        bodyView.isVerticallyResizable = true
        bodyView.isHorizontallyResizable = false
        bodyView.textContainer?.widthTracksTextView = true
        bodyView.delegate = self
        bodyView.setAccessibilityLabel(String(localized: "Commit description"))
        bodyView.setAccessibilityIdentifier("changes.commitDescription")
        bodyView.addSubview(bodyPlaceholder)
        bodyPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bodyPlaceholder.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor, constant: 9),
            bodyPlaceholder.topAnchor.constraint(equalTo: bodyView.topAnchor, constant: 5),
        ])
    }

    private func layoutFooter() {
        let topSeparator = Deck.separator()
        let subjectRow = Deck.hstack([field, countLabel], spacing: 6)
        subjectRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        subjectRow.heightAnchor.constraint(equalToConstant: Metrics.subjectHeight).isActive = true
        bodyHeightConstraint.isActive = true
        let composerStack = Deck.vstack([subjectRow, bodySeparator, bodyScroll], spacing: 0)
        Deck.pin(composerStack, in: composerBox)
        for view in [subjectRow, bodySeparator, bodyScroll] {
            view.widthAnchor.constraint(equalTo: composerStack.widthAnchor).isActive = true
        }
        let splitCommit = Deck.hstack([commitButton, commitMenuButton], spacing: 1)
        let actions = Deck.hstack(
            [recentButton, descriptionButton, assistController.button, Deck.spacer(), splitCommit], spacing: 4)
        let column = Deck.vstack([bannerBox, signingRow, composerBox, actions], spacing: Metrics.composerSpacing)
        let container = Deck.vstack([topSeparator, column], spacing: 0)
        Deck.pin(container, in: self)
        topSeparator.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        column.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        column.edgeInsets = Metrics.padding
        bannerBox.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16).isActive = true
        signingRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16).isActive = true
        composerBox.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16).isActive = true
        actions.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16).isActive = true
    }

    /// The combined commit message (`subject`, or `subject + "\n\n" + body` when description is non-empty).
    var message: String { CommitMessageText.join(subject: field.stringValue, body: bodyView.string) }

    /// Either text input is composing text (an input method): leave the text alone.
    var isComposing: Bool {
        (field.currentEditor() as? NSTextView)?.hasMarkedText() == true || bodyView.hasMarkedText()
    }

    /// Either text input currently has keyboard focus.
    var isEditing: Bool { field.currentEditor() != nil || (window?.firstResponder === bodyView) }

    var activeUndoManager: UndoManager { window?.undoManager ?? fallbackUndoManager }

    /// Shows `message` unless the user is composing. An open editor takes the same text, so toggling Amend replaces
    /// what is being typed.
    func show(message next: String) {
        guard !isComposing, !self.message.utf8.elementsEqual(next.utf8) else { return }
        applyDisplayedMessage(next, animated: true)
    }

    func applyDisplayedMessage(_ next: String, animated: Bool) {
        let parts = CommitMessageText.split(next)
        isUpdatingText = true
        if !field.stringValue.utf8.elementsEqual(parts.subject.utf8) {
            field.stringValue = parts.subject
            field.currentEditor()?.string = parts.subject
        }
        if !bodyView.string.utf8.elementsEqual(parts.body.utf8) {
            bodyView.string = parts.body
        }
        isUpdatingText = false
        refreshComposerUI(animated: animated)
    }

    func apply(_ state: CommitActionsState) {
        applyActionsState(state)
        field.isEnabled = state.canEditMessage
        field.toolTip = state.messageToolTip
        bodyView.isEditable = state.canEditMessage
        bodyView.toolTip = state.messageToolTip
        descriptionButton.isEnabled = state.canEditMessage
        recentButton.isEnabled = state.canEditMessage
        refreshComposerUI(animated: true)
    }

    func focusDescription() {
        isDescriptionFocused = true
        refreshComposerUI(animated: true)
        window?.makeFirstResponder(bodyView)
    }

    func collapseDescription() {
        isDescriptionFocused = false
        if window?.firstResponder === bodyView { window?.makeFirstResponder(field) }
        refreshComposerUI(animated: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        bodyView.textColor = Theme.text
        bodyView.insertionPointColor = Theme.text
        refreshComposerUI(animated: false)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleActionsKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    func refreshComposerUI(animated: Bool = false) {
        let remaining = CommitMessageText.remainingSubjectCharacters(field.stringValue)
        countLabel.stringValue = "\(remaining)"
        countLabel.textColor = remaining < 0 ? Theme.failure : Theme.tertiaryText
        countLabel.setAccessibilityLabel(String(localized: "\(remaining) characters remaining in subject"))
        bodyPlaceholder.isHidden = !bodyView.string.isEmpty
        updateDescriptionExpansion(animated: animated)
    }

    private func updateDescriptionExpansion(animated: Bool) {
        let expanded = isDescriptionFocused || !bodyView.string.isEmpty
        descriptionButton.background = expanded ? .selected : .hover
        guard expanded != isDescriptionExpanded || bodyHeightConstraint.constant != (expanded ? Metrics.bodyHeight : 0)
        else { return }
        isDescriptionExpanded = expanded
        bodySeparator.isHidden = !expanded
        let target: CGFloat = expanded ? Metrics.bodyHeight : 0
        if animated, window?.isVisible == true, !Deck.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.allowsImplicitAnimation = true
                bodyHeightConstraint.animator().constant = target
                window?.layoutIfNeeded()
            }
        } else {
            bodyHeightConstraint.constant = target
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidBeginEditing(_: Notification) { onBeginEditing?() }

    func controlTextDidChange(_: Notification) {
        guard !isUpdatingText else { return }
        refreshComposerUI(animated: false)
        onChange?(message)
    }

    func controlTextDidEndEditing(_: Notification) {
        guard !isUpdatingText else { return }
        onEndEditing?(message)
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.insertTab(_:))
        {
            focusDescription()
            return true
        }
        return false
    }

    // MARK: NSTextViewDelegate

    func textDidBeginEditing(_: Notification) {
        isDescriptionFocused = true
        refreshComposerUI(animated: true)
        onBeginEditing?()
    }

    func textDidChange(_: Notification) {
        guard !isUpdatingText else { return }
        refreshComposerUI(animated: false)
        onChange?(message)
    }

    func textDidEndEditing(_: Notification) {
        isDescriptionFocused = false
        refreshComposerUI(animated: true)
        guard !isUpdatingText else { return }
        onEndEditing?(message)
    }

    func textView(_: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertTab(_:)) {
            window?.selectNextKeyView(bodyView)
            return true
        }
        if selector == #selector(NSResponder.insertBacktab(_:)) {
            window?.makeFirstResponder(field)
            return true
        }
        return false
    }
}
