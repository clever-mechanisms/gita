import AppKit
import GitaCore

/// The merge editor in place of the code pane: a toolbar, Current · Result · Incoming with the gutters between them,
/// and the footer. It draws a `MergeEditorDisplay` and reports what the user does; `MergeEditorController` decides.
@MainActor
final class MergeEditorView: NSView, NSTextViewDelegate {
    enum Metrics {
        static let toolbarHeight: CGFloat = 32
        static let headerHeight: CGFloat = 34
        static let footerHeight: CGFloat = 40
    }

    let pathLabel = Style.label("", size: 12, weight: .semibold)
    let statusLabel = Style.label("", size: 11, weight: .medium, color: Theme.secondaryText)
    let previousButton = MergeEditorView.iconButton("chevron.up", String(localized: "Previous Change (⇧F7)"))
    let nextButton = MergeEditorView.iconButton("chevron.down", String(localized: "Next Change (F7)"))
    let applyAllButton = Style.button(
        String(localized: "Apply Non-Conflicting"), symbol: "arrow.left.arrow.right", target: nil, action: nil)
    let simpleButton = Style.button(
        String(localized: "Resolve Simple"), symbol: "wand.and.stars", target: nil, action: nil)
    let wordsButton = NSButton(checkboxWithTitle: String(localized: "Highlight words"), target: nil, action: nil)
    let oursPane = MergeTextView(editable: false, accessibilityLabel: String(localized: "Current version"))
    let resultPane = MergeTextView(editable: true, accessibilityLabel: String(localized: "Result"))
    let theirsPane = MergeTextView(editable: false, accessibilityLabel: String(localized: "Incoming version"))
    lazy var leftGutter = MergeGutterView(side: .ours, sidePane: oursPane, resultPane: resultPane)
    lazy var rightGutter = MergeGutterView(side: .theirs, sidePane: theirsPane, resultPane: resultPane)
    let oursTitle = Style.label("", size: 12, weight: .semibold)
    let oursDetail = Style.label("", size: 10.5, color: Theme.tertiaryText)
    let resultDetail = Style.label("", size: 10.5, color: Theme.tertiaryText)
    let theirsTitle = Style.label("", size: 12, weight: .semibold)
    let theirsDetail = Style.label("", size: 10.5, color: Theme.tertiaryText)
    let panes = NSView()
    let versions = MergeVersionsView()
    let messageTitle = Style.label("", size: 13, weight: .semibold)
    let messageDetail = Style.label("", size: 12, color: Theme.secondaryText)
    let messageReload = Style.button(String(localized: "Reload"), symbol: "arrow.clockwise", target: nil, action: nil)
    let messageReopen = Style.button(
        String(localized: "Reopen"), symbol: "arrow.uturn.backward", target: nil, action: nil)
    lazy var message = Style.stack(
        [messageTitle, messageDetail, Style.stack([messageReload, messageReopen])], vertical: true, spacing: 8)
    let progress = NSProgressIndicator()
    let errorLabel = Style.label("", size: 11, color: Theme.failure)
    let useOursButton = Style.button("", symbol: "arrow.right.to.line", target: nil, action: nil)
    let useTheirsButton = Style.button("", symbol: "arrow.left.to.line", target: nil, action: nil)
    let oursApplyButton = Style.button(
        String(localized: "Non-Conflicting"), symbol: "chevron.right.2", target: nil, action: nil)
    let theirsApplyButton = Style.button(
        String(localized: "Non-Conflicting"), symbol: "chevron.left.2", target: nil, action: nil)
    let workingButton = Style.button(
        String(localized: "Use Working File"), symbol: "doc.text", target: nil, action: nil)
    let resetButton = Style.button(
        String(localized: "Reset"), symbol: "arrow.counterclockwise", target: nil, action: nil)
    let reloadButton = Style.button(String(localized: "Reload"), symbol: "arrow.clockwise", target: nil, action: nil)
    let saveButton = Style.button(String(localized: "Save & Stage"), symbol: "checkmark", target: nil, action: nil)

    var onAction: ((MergeAction) -> Void)?
    var onSave: (() -> Void)?
    var onReload: (() -> Void)?
    var onReopen: (() -> Void)?
    var onWords: ((Bool) -> Void)?
    /// The panes are being scrolled to follow another one.
    var isSyncing = false
    var layoutShown = MergeLayout(spans: [])
    var currentShown: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Style.fill(ThemedBackgroundView(), in: self)
        buildInterface()
        wireControls()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    static func iconButton(_ symbol: String, _ help: String) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(), target: nil,
            action: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = help
        button.setAccessibilityLabel(help)
        return button
    }

    private func wireControls() {
        let targets: [(NSButton, Selector)] = [
            (previousButton, #selector(previousPressed)), (nextButton, #selector(nextPressed)),
            (simpleButton, #selector(simplePressed)), (wordsButton, #selector(wordsPressed)),
            (applyAllButton, #selector(applyAllPressed)), (oursApplyButton, #selector(oursApplyPressed)),
            (theirsApplyButton, #selector(theirsApplyPressed)),
            (useOursButton, #selector(useOursPressed)), (useTheirsButton, #selector(useTheirsPressed)),
            (workingButton, #selector(workingPressed)), (resetButton, #selector(resetPressed)),
            (reloadButton, #selector(reloadPressed)),
            (messageReload, #selector(reloadPressed)), (messageReopen, #selector(reopenPressed)),
            (saveButton, #selector(savePressed)),
        ]
        for (button, action) in targets {
            button.target = self
            button.action = action
        }
        let f7 = String(utf16CodeUnits: [UInt16(NSF7FunctionKey)], count: 1)
        nextButton.keyEquivalent = f7
        nextButton.keyEquivalentModifierMask = []
        previousButton.keyEquivalent = f7
        previousButton.keyEquivalentModifierMask = .shift
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.toolTip = String(localized: "Save & Stage (⌘↩)")
        saveButton.setAccessibilityIdentifier("merge.save")
        wordsButton.state = .on
        resultPane.delegate = self
        for gutter in [leftGutter, rightGutter] { gutter.onAction = { [weak self] in self?.onAction?($0) } }
        versions.onChoose = { [weak self] side in self?.onAction?(.choose(side)) }
        for pane in [oursPane, resultPane, theirsPane] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(paneScrolled(_:)), name: NSView.boundsDidChangeNotification,
                object: pane.enclosingScrollView?.contentView)
        }
    }

    @objc private func previousPressed() { onAction?(.navigate(forward: false)) }
    @objc private func nextPressed() { onAction?(.navigate(forward: true)) }
    @objc private func simplePressed() { onAction?(.simpleAll) }
    @objc private func wordsPressed() { onWords?(wordsButton.state == .on) }
    @objc private func useOursPressed() { onAction?(.whole(.ours)) }
    @objc private func useTheirsPressed() { onAction?(.whole(.theirs)) }
    @objc private func workingPressed() { onAction?(.working) }
    @objc private func resetPressed() { onAction?(.reset) }
    @objc private func reloadPressed() { onReload?() }
    @objc private func reopenPressed() { onReopen?() }
    @objc private func savePressed() { onSave?() }
    @objc private func applyAllPressed() { onAction?(.nonConflicting(nil)) }
    @objc private func oursApplyPressed() { onAction?(.nonConflicting(.ours)) }
    @objc private func theirsApplyPressed() { onAction?(.nonConflicting(.theirs)) }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? MergeTextView === resultPane else { return }
        onAction?(.edit(resultPane.string))
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard textView === resultPane, let text else { return true }
        let length = textView.string.utf16.count - range.length + text.utf16.count
        return length <= MergeEditorState.maximumTextSize
    }

    /// One pane scrolled: the others follow line for line, and the gutters and line numbers redraw.
    @objc private func paneScrolled(_ notification: Notification) {
        if !isSyncing, let clip = notification.object as? NSClipView { follow(clip) }
        leftGutter.refresh()
        rightGutter.refresh()
        for pane in [oursPane, resultPane, theirsPane] { pane.lineNumbers?.needsDisplay = true }
    }

    private func follow(_ clip: NSClipView) {
        let panes: [(MergePane, MergeTextView)] = [(.ours, oursPane), (.result, resultPane), (.theirs, theirsPane)]
        guard let source = panes.first(where: { $0.1.enclosingScrollView?.contentView === clip }) else { return }
        isSyncing = true
        defer { isSyncing = false }
        let top = source.1.topLine
        let fraction = top - top.rounded(.down)
        for (pane, view) in panes where pane != source.0 {
            view.scroll(toLine: CGFloat(layoutShown.line(Int(top), from: source.0, to: pane)) + fraction)
        }
    }
}
