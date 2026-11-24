import AppKit
import GitaCore

/// Popover for diff options: Ignore Whitespace (`-w`), Context (`3 / 10 / 25 / Whole file`),
/// and Tab Width (`2 / 4 / 8`).
@MainActor
final class DiffOptionsPopoverController: NSViewController {
    private let whitespaceCheck = NSButton(
        checkboxWithTitle: String(localized: "Ignore whitespace (-w)"), target: nil, action: nil)
    private let contextControl = NSSegmentedControl(
        labels: [
            "3", "10", "25", String(localized: "Whole file"),
        ], trackingMode: .selectOne, target: nil, action: nil)
    private let tabWidthControl = NSSegmentedControl(
        labels: DiffPreference.allowedTabWidths.map(String.init), trackingMode: .selectOne, target: nil, action: nil)

    var options: DiffOptions
    var defaults: UserDefaults
    var onChangeOptions: ((DiffOptions) -> Void)?

    init(options: DiffOptions, defaults: UserDefaults) {
        self.options = options
        self.defaults = defaults
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("DiffOptionsPopoverController is built in code") }

    override func loadView() {
        whitespaceCheck.font = Theme.body
        whitespaceCheck.target = self
        whitespaceCheck.action = #selector(toggleWhitespace)
        whitespaceCheck.setAccessibilityIdentifier("diff.ignoreWhitespace")

        contextControl.controlSize = .small
        contextControl.font = Theme.caption
        contextControl.target = self
        contextControl.action = #selector(changeContext)
        contextControl.setAccessibilityIdentifier("diff.contextControl")

        tabWidthControl.controlSize = .small
        tabWidthControl.font = Theme.caption
        tabWidthControl.target = self
        tabWidthControl.action = #selector(changeTabWidth)
        tabWidthControl.setAccessibilityIdentifier("diff.tabWidthControl")

        let contextLabel = Style.label(String(localized: "Context"), size: 11, color: Theme.secondaryText)
        let tabLabel = Style.label(String(localized: "Tab width"), size: 11, color: Theme.secondaryText)
        let contextRow = Style.stack([contextLabel, contextControl], spacing: 8)
        let tabRow = Style.stack([tabLabel, tabWidthControl], spacing: 8)

        let stack = Style.stack([whitespaceCheck, contextRow, tabRow], vertical: true, spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 112))
        Style.fill(stack, in: container)
        view = container
        syncControls()
    }

    func syncControls() {
        whitespaceCheck.state = options.ignoreWhitespace ? .on : .off
        switch options.context {
        case ..<10: contextControl.selectedSegment = 0
        case 10..<25: contextControl.selectedSegment = 1
        case 25..<DiffOptions.wholeFileContext: contextControl.selectedSegment = 2
        default: contextControl.selectedSegment = 3
        }
        let width = DiffPreference.tabWidth(defaults)
        if let index = DiffPreference.allowedTabWidths.firstIndex(of: width) {
            tabWidthControl.selectedSegment = index
        }
    }

    @objc private func toggleWhitespace() {
        options.ignoreWhitespace = whitespaceCheck.state == .on
        DiffPreference.setIgnoreWhitespace(options.ignoreWhitespace, in: defaults)
        onChangeOptions?(options)
    }

    @objc private func changeContext() {
        let selected = contextControl.selectedSegment
        let steps = DiffOptions.contextSteps + [DiffOptions.wholeFileContext]
        guard steps.indices.contains(selected) else { return }
        options.context = steps[selected]
        onChangeOptions?(options)
    }

    @objc private func changeTabWidth() {
        let selected = tabWidthControl.selectedSegment
        guard DiffPreference.allowedTabWidths.indices.contains(selected) else { return }
        DiffPreference.setTabWidth(DiffPreference.allowedTabWidths[selected], in: defaults)
    }
}

/// Inline notice banner shown when Ignore Whitespace (`-w`) disables hunk and line staging.
@MainActor
final class DiffWhitespaceNoticeView: NSView {
    static let height: CGFloat = 26

    private let icon = Deck.icon("info.circle.fill", size: 11, color: Theme.needsInputText)
    private let label = Style.label(
        String(localized: "Hunk staging is off while whitespace is ignored."), size: 11, color: Theme.needsInputText)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = Style.stack([icon, label], spacing: 6)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        Style.fill(stack, in: self)
        setAccessibilityIdentifier("diff.whitespaceNotice")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("DiffWhitespaceNoticeView is built in code") }

    override func draw(_: NSRect) {
        Theme.needsInput.withAlphaComponent(0.14).setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
