import AppKit
import GitaCore

/// A conflict that is not merged line by line (a deletion, an image or other binary file, a link, a submodule):
/// both sides next to each other, each with its content and the button that keeps it.
@MainActor
final class MergeVersionsView: NSView {
    /// One side: header with the button, then the text, the image or a placeholder.
    @MainActor
    final class Column {
        let title = Style.label("", size: 12, weight: .semibold)
        let detail = Style.label("", size: 10.5, color: Theme.tertiaryText)
        let button = Style.button("", symbol: "checkmark.circle", target: nil, action: nil)
        let header = ThemedBackgroundView()
        let text = MergeTextView(editable: false, accessibilityLabel: "")
        lazy var textBox = text.embedded()
        let image = NSImageView()
        let caption = Style.label("", size: 11, color: Theme.secondaryText)
        lazy var imageBox = Style.stack([image, caption], vertical: true, spacing: 8)
        let placeholderIcon = NSImageView()
        let placeholder = Style.label("", size: 13, color: Theme.secondaryText)
        lazy var placeholderBox = Style.stack([placeholderIcon, placeholder], vertical: true, spacing: 8)
        let view = ThemedBackgroundView()
    }

    private let explanation = Style.label("", size: 12, color: Theme.secondaryText)
    private(set) var columns: [MergeSide: Column] = [:]
    var onChoose: ((MergeSide) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let strip = ThemedBackgroundView()
        strip.color = Theme.inset
        let stripStack = Style.stack([explanation])
        stripStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        Style.fill(stripStack, in: strip)
        let built = MergeSide.allCases.map { side in (side, build(side)) }
        columns = Dictionary(uniqueKeysWithValues: built)
        let views = [strip] + built.map(\.1.view)
        for view in views {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let left = built[0].1.view
        let right = built[1].1.view
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor), strip.heightAnchor.constraint(equalToConstant: 28),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 1),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.widthAnchor.constraint(equalTo: left.widthAnchor),
            left.topAnchor.constraint(equalTo: strip.bottomAnchor),
            right.topAnchor.constraint(equalTo: strip.bottomAnchor),
            left.bottomAnchor.constraint(equalTo: bottomAnchor), right.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    private func build(_ side: MergeSide) -> Column {
        let column = Column()
        column.view.color = Theme.window
        column.header.color = Theme.toolbar
        column.button.target = self
        column.button.action = #selector(chosen(_:))
        column.button.tag = side == .ours ? 0 : 1
        column.button.setAccessibilityIdentifier("merge.keep.\(side)")
        column.image.imageScaling = .scaleProportionallyDown
        column.placeholderIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        column.placeholderIcon.contentTintColor = Theme.tertiaryText
        for label in [column.title, column.detail] { label.lineBreakMode = .byTruncatingTail }
        let labels = Style.stack([column.title, column.detail], vertical: true, spacing: 1)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = Style.stack([labels, spacer, column.button])
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        Style.fill(bar, in: column.header)
        for view in [column.header, column.textBox, column.imageBox, column.placeholderBox] as [NSView] {
            column.view.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let header = column.header
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: column.view.topAnchor),
            header.leadingAnchor.constraint(equalTo: column.view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: column.view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: MergeEditorView.Metrics.headerHeight),
            column.textBox.topAnchor.constraint(equalTo: header.bottomAnchor),
            column.textBox.leadingAnchor.constraint(equalTo: column.view.leadingAnchor),
            column.textBox.trailingAnchor.constraint(equalTo: column.view.trailingAnchor),
            column.textBox.bottomAnchor.constraint(equalTo: column.view.bottomAnchor),
            column.imageBox.centerXAnchor.constraint(equalTo: column.view.centerXAnchor),
            column.imageBox.centerYAnchor.constraint(equalTo: column.textBox.centerYAnchor),
            column.image.widthAnchor.constraint(lessThanOrEqualTo: column.view.widthAnchor, constant: -40),
            column.image.heightAnchor.constraint(lessThanOrEqualTo: column.textBox.heightAnchor, constant: -60),
            column.placeholderBox.centerXAnchor.constraint(equalTo: column.view.centerXAnchor),
            column.placeholderBox.centerYAnchor.constraint(equalTo: column.textBox.centerYAnchor),
            column.placeholder.widthAnchor.constraint(lessThanOrEqualTo: column.view.widthAnchor, constant: -40),
        ])
        column.placeholderBox.alignment = .centerX
        column.imageBox.alignment = .centerX
        column.placeholder.alignment = .center
        column.placeholder.lineBreakMode = .byWordWrapping
        column.placeholder.maximumNumberOfLines = 3
        return column
    }

    func show(explanation text: String, versions: [MergeEditorDisplay.Version], enabled: Bool) {
        explanation.stringValue = text
        for version in versions {
            guard let column = columns[version.side] else { continue }
            column.title.stringValue = version.title
            column.detail.stringValue = version.detail
            column.button.title = version.action
            column.button.image = NSImage(systemSymbolName: version.symbol, accessibilityDescription: version.action)
            column.button.isEnabled = enabled && version.isEnabled
            column.header.color = version.isChosen ? Theme.selection : Theme.toolbar
            column.text.setAccessibilityLabel(version.title)
            show(version, in: column)
        }
    }

    private func show(_ version: MergeEditorDisplay.Version, in column: Column) {
        column.textBox.isHidden = true
        column.imageBox.isHidden = true
        column.placeholderBox.isHidden = true
        switch version.preview {
        case .text(let text):
            column.textBox.isHidden = false
            let pane = MergePaneDisplay(text: text, lineCount: MergeText.lines(text).count)
            column.text.show(pane, font: TextLines.monospaced(11))
        case .data(let data):
            if let image = NSImage(data: data) {
                column.imageBox.isHidden = false
                column.image.image = image
                let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                column.caption.stringValue = "\(Int(image.size.width)) × \(Int(image.size.height)) · \(size)"
            } else {
                showPlaceholder(version.placeholder, symbol: "doc", in: column)
            }
        case .deleted: showPlaceholder(version.placeholder, symbol: "trash", in: column)
        case .loading: showPlaceholder(version.placeholder, symbol: "hourglass", in: column)
        case .note: showPlaceholder(version.placeholder, symbol: "info.circle", in: column)
        }
    }

    private func showPlaceholder(_ text: String, symbol: String, in column: Column) {
        column.placeholderBox.isHidden = false
        column.placeholder.stringValue = text
        column.placeholderIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
    }

    @objc private func chosen(_ sender: NSButton) { onChoose?(sender.tag == 0 ? .ours : .theirs) }
}
