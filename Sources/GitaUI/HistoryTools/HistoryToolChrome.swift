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

/// Shared list pane used by Reflog, Line History, and Code Search windows.
@MainActor
final class HistoryToolTablePane: RowView {
    let table = NSTableView()
    let emptyLabel = Deck.label("", font: Theme.body, color: Theme.secondaryText)

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
        emptyLabel.alignment = .center
        var children: [NSView] = [scroll, emptyLabel]
        if let footer { children.append(footer) }
        for view in children {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        var constraints = [
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
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

/// Shared layout helpers used across HistoryTools windows to avoid boilerplate chrome duplication.
@MainActor
enum HistoryToolChrome {
    struct SplitWindowSpec {
        let title: String
        let size: NSSize
        let minSize: NSSize
        let topBar: NSView
        var topBarHeight: CGFloat?
        let list: NSView
        let detail: NSView
        let dividerPosition: CGFloat
    }

    static func makeSplitWindow(_ spec: SplitWindowSpec, delegate: any NSWindowDelegate) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: spec.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        win.title = spec.title
        win.minSize = spec.minSize
        win.isReleasedWhenClosed = false
        win.delegate = delegate

        let root = ThemedBackgroundView()
        win.contentView = root
        let divider = Deck.separator()
        let split = DeckSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(spec.list)
        split.addArrangedSubview(spec.detail)

        for view in [spec.topBar, divider, split] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        var constraints = [
            spec.topBar.topAnchor.constraint(equalTo: root.topAnchor),
            spec.topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            spec.topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.topAnchor.constraint(equalTo: spec.topBar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: divider.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
        if let topBarHeight = spec.topBarHeight {
            constraints.append(spec.topBar.heightAnchor.constraint(equalToConstant: topBarHeight))
        }
        NSLayoutConstraint.activate(constraints)
        split.setPosition(spec.dividerPosition, ofDividerAt: 0)
        win.center()
        return win
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
}
