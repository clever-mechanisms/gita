import AppKit

/// Local Changes' footer: single-line commit subject with GitHub's 50-character guideline counter, multi-line
/// description textarea, and the Stage all / Amend Last Commit / Commit staged controls below.
@MainActor
final class CommitFooterView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    private enum Metrics {
        static let subjectHeight: CGFloat = 28
        static let bodyHeight: CGFloat = 62
        static let composerSpacing: CGFloat = 8
        static let padding = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
    }

    let field = NSTextField()
    let bodyView = NSTextView()
    let countLabel = Deck.caption("")
    let commitButton = Style.button(
        String(localized: "Commit staged"), symbol: "checkmark", target: nil, action: nil)
    let stageAllButton = Style.button(String(localized: "Stage all"), symbol: "plus.square", target: nil, action: nil)
    let amendButton = NSButton(checkboxWithTitle: String(localized: "Amend Last Commit"), target: nil, action: nil)

    private let composerBox = FillView(color: Theme.window)
    private let bodyScroll = NSScrollView()
    private let bodyPlaceholder = Deck.label(
        String(localized: "Description"), font: Theme.body, color: Theme.tertiaryText)
    private var isUpdatingText = false

    var onStageAll: (() -> Void)?
    var onCommit: (() -> Void)?
    var onAmend: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    var onChange: ((String) -> Void)?
    var onEndEditing: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureButtons()
        configureComposer()
        layoutFooter()
        refreshComposerUI()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    private func configureButtons() {
        commitButton.target = self
        commitButton.action = #selector(commitPressed)
        stageAllButton.target = self
        stageAllButton.action = #selector(stageAllPressed)
        amendButton.target = self
        amendButton.action = #selector(amendPressed)
        amendButton.font = TextLines.system(12)
        amendButton.controlSize = .small
        amendButton.setContentHuggingPriority(.required, for: .horizontal)
        amendButton.setAccessibilityIdentifier("changes.amendLastCommit")
    }

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
        let subjectRow = Deck.hstack([field, countLabel], spacing: 6)
        subjectRow.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        subjectRow.heightAnchor.constraint(equalToConstant: Metrics.subjectHeight).isActive = true
        let separator = Deck.separator()
        bodyScroll.heightAnchor.constraint(equalToConstant: Metrics.bodyHeight).isActive = true
        let composerStack = Deck.vstack([subjectRow, separator, bodyScroll], spacing: 0)
        Deck.pin(composerStack, in: composerBox)
        for view in [subjectRow, separator, bodyScroll] {
            view.widthAnchor.constraint(equalTo: composerStack.widthAnchor).isActive = true
        }
        let actions = Deck.hstack([stageAllButton, amendButton, Deck.spacer(), commitButton], spacing: 10)
        let column = Deck.vstack([composerBox, actions], spacing: Metrics.composerSpacing)
        Deck.pin(column, in: self, insets: Metrics.padding)
        composerBox.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        actions.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    @objc private func commitPressed() { onCommit?() }
    @objc private func stageAllPressed() { onStageAll?() }
    @objc private func amendPressed() { onAmend?() }

    /// The combined commit message (`subject`, or `subject + "\n\n" + body` when description is non-empty).
    var message: String { CommitMessageText.join(subject: field.stringValue, body: bodyView.string) }

    /// Either text input is composing text (an input method): leave the text alone.
    var isComposing: Bool {
        (field.currentEditor() as? NSTextView)?.hasMarkedText() == true || bodyView.hasMarkedText()
    }

    /// Either text input currently has keyboard focus.
    var isEditing: Bool { field.currentEditor() != nil || (window?.firstResponder === bodyView) }

    /// Shows `message` unless the user is composing. An open editor takes the same text, so toggling Amend replaces
    /// what is being typed.
    func show(message next: String) {
        guard !isComposing, !self.message.utf8.elementsEqual(next.utf8) else { return }
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
        refreshComposerUI()
    }

    func apply(_ state: CommitActionsState) {
        commitButton.isEnabled = state.canCommit
        commitButton.title = state.commitTitle
        commitButton.toolTip = state.commitToolTip
        stageAllButton.isEnabled = state.canStageAll
        stageAllButton.title = state.stageAllTitle
        field.isEnabled = state.canEditMessage
        field.toolTip = state.messageToolTip
        bodyView.isEditable = state.canEditMessage
        bodyView.toolTip = state.messageToolTip
        amendButton.isEnabled = state.canAmend
        amendButton.state = state.amendChecked ? .on : .off
        amendButton.toolTip = state.amendToolTip
        refreshComposerUI()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        bodyView.textColor = Theme.text
        bodyView.insertionPointColor = Theme.text
        refreshComposerUI()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == KeyPress.returnKey || event.keyCode == KeyPress.keypadEnter
        if flags == .command, isReturn, isEditing, commitButton.isEnabled {
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func refreshComposerUI() {
        let remaining = CommitMessageText.remainingSubjectCharacters(field.stringValue)
        countLabel.stringValue = "\(remaining)"
        countLabel.textColor = remaining < 0 ? Theme.failure : Theme.tertiaryText
        countLabel.setAccessibilityLabel(String(localized: "\(remaining) characters remaining in subject"))
        bodyPlaceholder.isHidden = !bodyView.string.isEmpty
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidBeginEditing(_: Notification) { onBeginEditing?() }

    func controlTextDidChange(_: Notification) {
        guard !isUpdatingText else { return }
        refreshComposerUI()
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
            window?.makeFirstResponder(bodyView)
            return true
        }
        return false
    }

    // MARK: NSTextViewDelegate

    func textDidBeginEditing(_: Notification) { onBeginEditing?() }

    func textDidChange(_: Notification) {
        guard !isUpdatingText else { return }
        refreshComposerUI()
        onChange?(message)
    }

    func textDidEndEditing(_: Notification) {
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
