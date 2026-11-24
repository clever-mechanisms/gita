import AppKit
import GitaCore

/// A section of Local Changes (Unstaged or Staged): its title and count, the Stage or Unstage button, its files.
@MainActor
final class ChangedFilesSection: NSView {
    private enum Metrics {
        static let headerHeight: CGFloat = 30
        static let minimumHeight: CGFloat = 76
        static let headerInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
    }
    let list: ChangedFilesView
    let button: NSButton
    private let title: NSTextField
    private let count = Deck.caption("")

    init(side: ChangedFilesView.Side, title text: String, button: NSButton) {
        list = ChangedFilesView(side: side)
        self.button = button
        title = Deck.sectionTitle(text)
        super.init(frame: .zero)
        count.textColor = Theme.tertiaryText
        button.setContentHuggingPriority(.required, for: .horizontal)
        // In a narrow pane (or a long translation) the button's title shortens before the section's name does.
        button.setContentCompressionResistancePriority(.init(745), for: .horizontal)
        (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        // Title and count keep their widths; the spacer takes the rest, and a narrow pane shortens the title first.
        for label in [title, count] { label.setContentHuggingPriority(.required, for: .horizontal) }
        title.setContentCompressionResistancePriority(.init(749), for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.toolTip = button.toolTip ?? button.title
        let header = Deck.hstack([title, count, Deck.spacer(), button], spacing: 6)
        header.edgeInsets = Metrics.headerInsets
        for view in [header, list] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: header.bottomAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumHeight).isActive = true
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ChangedFilesSection is built in code") }

    func update(_ files: [FileChange]) {
        list.update(files)
        count.stringValue = files.isEmpty ? "" : "\(files.count)"
        setAccessibilityLabel(title.stringValue)
        setAccessibilityValue("\(files.count)")
    }
}
