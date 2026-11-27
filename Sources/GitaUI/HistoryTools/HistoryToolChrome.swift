import AppKit
import GitaCore

/// Compact rounded pill label with dynamic Theme tinting and optional monospaced digits for counts/SHAs.
@MainActor
final class HistoryToolBadgePill: NSView {
    private let label: NSTextField
    private var tintColor: NSColor = Theme.secondaryText

    init(monospaced: Bool = false, monospacedDigits: Bool = false) {
        let font: NSFont =
            if monospaced {
                Theme.mono
            } else if monospacedDigits {
                NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            } else {
                Theme.captionEmphasis
            }
        self.label = Deck.label("", font: font, color: Theme.text)
        super.init(frame: .zero)
        wantsLayer = true
        label.alignment = .center
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        Deck.pin(label, in: self, insets: NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func apply(title: String, color: NSColor) {
        tintColor = color
        label.stringValue = title
        label.textColor = color
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 4
        layer?.backgroundColor = tintColor.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = tintColor.withAlphaComponent(0.35).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Unified `Theme.toolbar` inline header bar with optional Back button, `StorageStyle.iconBadge`, title/subtitle,
/// and trailing action controls.
@MainActor
final class HistoryToolHeaderBar: RowView {
    struct Spec {
        let symbol: String
        var tint: NSColor?
        let title: String
        var subtitle: String = ""
        var titleAccessories: [NSView] = []
        var trailing: [NSView] = []
    }

    var onBack: (() -> Void)? {
        didSet { backButton.isHidden = onBack == nil }
    }

    var isBackEnabled: Bool {
        get { backButton.isEnabled }
        set { backButton.isEnabled = newValue }
    }

    private let backButton: PartsButton
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField

    init(_ spec: Spec) {
        self.backButton = StorageStyle.actionButton(
            String(localized: "Back"), symbol: "chevron.left", style: .quiet,
            accessibility: String(localized: "Back")
        ) {}
        self.titleLabel = Deck.label(spec.title, font: TextLines.system(13.5, weight: .semibold), color: Theme.text)
        self.subtitleLabel = Deck.caption(spec.subtitle)
        super.init(frame: .zero)
        hoverEnabled = false
        fill = Theme.toolbar
        backButton.setAccessibilityIdentifier("historyTool.back")
        backButton.isHidden = true
        backButton.onClick = { [weak self] in self?.onBack?() }
        subtitleLabel.isHidden = spec.subtitle.isEmpty

        let badge = StorageStyle.iconBadge(
            spec.symbol, tint: spec.tint ?? Theme.accent, boxSize: 30, symbolSize: 14, cornerRadius: 7)
        let titleRow = Deck.hstack([titleLabel] + spec.titleAccessories, spacing: 6)
        let titleBlock = Deck.vstack([titleRow, subtitleLabel], spacing: 1)
        titleBlock.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var items: [NSView] = [backButton, badge, titleBlock, Deck.spacer()]
        if !spec.trailing.isEmpty {
            items.append(Deck.hstack(spec.trailing, spacing: 8))
        }
        let row = Deck.hstack(items, spacing: 10)
        Deck.pin(row, in: self, insets: NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14))
        heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func setSubtitle(_ text: String) {
        subtitleLabel.stringValue = text
        subtitleLabel.isHidden = text.isEmpty
        subtitleLabel.toolTip = text
    }
}

/// Centered empty/loading/error state with SF Symbol badge and helpful message text.
@MainActor
final class HistoryToolEmptyStateView: NSView {
    let titleLabel = Deck.wrapping("", font: Theme.bodyEmphasis, color: Theme.secondaryText)
    private let detailLabel = Deck.wrapping("", font: Theme.caption, color: Theme.tertiaryText)
    private let iconView = NSImageView()
    private let iconBox = FillView(color: Theme.control)

    init(symbol: String = "tray", extraViews: [NSView] = []) {
        super.init(frame: .zero)
        iconBox.cornerRadius = 10
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setSymbol(symbol, size: 18, weight: .medium, color: Theme.secondaryText)
        iconBox.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 40),
            iconBox.heightAnchor.constraint(equalToConstant: 40),
            iconView.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
        ])
        titleLabel.alignment = .center
        detailLabel.alignment = .center
        detailLabel.isHidden = true
        let stack = Deck.vstack([iconBox, titleLabel, detailLabel] + extraViews, spacing: 8)
        stack.alignment = .centerX
        Deck.pin(stack, in: self)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func apply(hidden: Bool, symbol: String, title: String, detail: String = "", tint: NSColor = Theme.secondaryText) {
        isHidden = hidden
        guard !hidden else { return }
        iconView.setSymbol(symbol, size: 18, weight: .medium, color: tint)
        iconBox.color = tint.withAlphaComponent(0.12)
        titleLabel.stringValue = title
        titleLabel.textColor = tint == Theme.failure ? Theme.failure : Theme.secondaryText
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
    }
}

/// Shared list pane used by Reflog, Line History, and Code Search inline views.
@MainActor
final class HistoryToolTablePane: RowView {
    let table = NSTableView()
    let emptyState = HistoryToolEmptyStateView()

    init(
        columnID: String,
        rowHeight: CGFloat,
        accessibilityLabel: String,
        accessibilityID: String,
        footer: NSView? = nil
    ) {
        super.init(frame: .zero)
        hoverEnabled = false
        fill = Theme.window
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(columnID))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = Theme.window
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(accessibilityLabel)
        table.setAccessibilityIdentifier(accessibilityID)

        let scroll = Style.scroll(table)
        var children: [NSView] = [scroll, emptyState]
        if let footer { children.append(footer) }
        for view in children {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        var constraints = [
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ]
        if let footer {
            constraints += [
                scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
                footer.leadingAnchor.constraint(equalTo: leadingAnchor),
                footer.trailingAnchor.constraint(equalTo: trailingAnchor),
                footer.bottomAnchor.constraint(equalTo: bottomAnchor),
                footer.heightAnchor.constraint(equalToConstant: 26),
            ]
        } else {
            constraints.append(scroll.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }
}

/// Compact per-file selector strip so multi-file commits load one file at a time in `DiffView`.
@MainActor
final class HistoryToolFileBar: NSView {
    var onSelectFile: ((String) -> Void)?

    private let icon = Deck.icon("doc.text", size: 11, color: Theme.secondaryText)
    private let countPill = HistoryToolBadgePill(monospacedDigits: true)
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var paths: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        picker.controlSize = .small
        picker.font = Theme.caption
        picker.target = self
        picker.action = #selector(filePicked)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.setAccessibilityLabel(String(localized: "Select changed file"))
        picker.setAccessibilityIdentifier("historyTool.filePicker")

        let row = Deck.hstack([icon, countPill, picker, Deck.spacer()], spacing: 8)
        Deck.pin(row, in: self, insets: NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 14))
        isHidden = true
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func apply(paths nextPaths: [String], selected: String?) {
        paths = nextPaths
        isHidden = nextPaths.isEmpty
        guard !nextPaths.isEmpty else { return }
        let label = nextPaths.count == 1 ? String(localized: "1 file") : String(localized: "\(nextPaths.count) files")
        countPill.apply(title: label, color: Theme.working)
        picker.removeAllItems()
        picker.addItems(withTitles: nextPaths)
        if let selected, let index = nextPaths.firstIndex(of: selected) {
            picker.selectItem(at: index)
        } else {
            picker.selectItem(at: 0)
        }
        picker.isEnabled = nextPaths.count > 1
        needsDisplay = true
    }

    @objc private func filePicked() {
        let index = picker.indexOfSelectedItem
        guard paths.indices.contains(index) else { return }
        onSelectFile?(paths[index])
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.inset.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Shared detail pane hosting a header stack, optional banner, optional per-file selector, separator, and `DiffView`.
@MainActor
final class HistoryToolDetailPane: RowView {
    let fileBar = HistoryToolFileBar()
    let diffView = DiffView()

    init(headerContent: NSView, banner: NSView? = nil, showsFileBar: Bool, repositoryRoot: URL?) {
        super.init(frame: .zero)
        hoverEnabled = false
        fill = Theme.window
        diffView.repositoryRoot = repositoryRoot
        let header = NSView()
        Deck.pin(headerContent, in: header, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        let topStack = Deck.vstack([], spacing: 0)
        topStack.alignment = .leading
        topStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: topStack.widthAnchor).isActive = true
        if let banner {
            topStack.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: topStack.widthAnchor).isActive = true
        }
        if showsFileBar {
            let fileDivider = Deck.separator()
            topStack.addArrangedSubview(fileDivider)
            fileDivider.widthAnchor.constraint(equalTo: topStack.widthAnchor).isActive = true
            topStack.addArrangedSubview(fileBar)
            fileBar.widthAnchor.constraint(equalTo: topStack.widthAnchor).isActive = true
        }
        let divider = Deck.separator()

        for view in [topStack, divider, diffView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: topAnchor),
            topStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: topStack.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            diffView.leadingAnchor.constraint(equalTo: leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }
}

/// Shared layout helpers used across HistoryTools inline controllers.
@MainActor
enum HistoryToolChrome {
    struct InlineSplitSpec {
        let header: NSView
        var subBar: NSView?
        let list: NSView
        let detail: NSView
        let dividerPosition: CGFloat
    }

    struct SegmentSpec {
        let title: String
        let symbol: String
    }

    static func makeInlineSplitView(_ spec: InlineSplitSpec) -> NSView {
        let root = ThemedBackgroundView()
        let split = DeckSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(borderedSurface(spec.list))
        split.addArrangedSubview(borderedSurface(spec.detail))

        let body = NSView()
        Deck.pin(split, in: body, insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))

        var sections: [NSView] = [spec.header, Deck.separator()]
        if let subBar = spec.subBar {
            sections += [subBar, Deck.separator()]
        }
        sections.append(body)

        var previous: NSView?
        for section in sections {
            section.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(section)
            let top = previous?.bottomAnchor ?? root.topAnchor
            NSLayoutConstraint.activate([
                section.topAnchor.constraint(equalTo: top),
                section.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                section.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            previous = section
        }
        body.bottomAnchor.constraint(equalTo: root.bottomAnchor).isActive = true
        split.setPosition(spec.dividerPosition, ofDividerAt: 0)
        return root
    }

    static func borderedSurface(_ content: NSView) -> NSView {
        let card = FillView(color: Theme.window)
        card.borderColor = Theme.separator
        card.cornerRadius = 8
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.masksToBounds = true
        Deck.pin(content, in: card, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        return card
    }

    static func configureSegmentedControl(
        _ control: NSSegmentedControl,
        segments: [SegmentSpec],
        target: AnyObject,
        action: Selector
    ) {
        control.segmentCount = segments.count
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.controlSize = .small
        for (idx, segment) in segments.enumerated() {
            control.setLabel(segment.title, forSegment: idx)
            control.setImage(Deck.template(segment.symbol, size: 11, weight: .medium), forSegment: idx)
            control.setImageScaling(.scaleProportionallyDown, forSegment: idx)
        }
        control.selectedSegment = 0
        control.target = target
        control.action = action
    }

    static func reloadTable(_ table: NSTableView?, selectedIndex: Int?) {
        guard let table else { return }
        table.reloadData()
        if let selectedIndex {
            table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }
    }

    static func pinRowStack(_ rows: [NSView], in parent: NSView) {
        let stack = Deck.vstack(rows, spacing: 3)
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        Deck.pin(stack, in: parent, insets: NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12))
    }

    static func commitMetaText(for commit: GitCommit) -> String {
        "\(String(commit.id.prefix(7))) · \(commit.author)"
    }

    static func commitDetailMeta(for commit: GitCommit) -> String {
        "\(commitMetaText(for: commit)) · \(DeckFormat.relative(commit.date))"
    }

    static func repositoryDisplayName(_ name: String?, root: URL?) -> String {
        name ?? root?.lastPathComponent ?? String(localized: "Repository")
    }

    static func observeTheme(_ observer: AnyObject, selector: Selector) {
        NotificationCenter.default.addObserver(observer, selector: selector, name: .gitaThemeChanged, object: nil)
    }

    static func copySHAButton(_ action: @escaping () -> Void) -> PartsButton {
        PartsButton.quiet(String(localized: "Copy SHA"), symbol: "doc.on.doc", action: action)
    }
}
