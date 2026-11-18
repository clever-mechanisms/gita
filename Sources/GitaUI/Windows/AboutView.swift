import AppKit
import GitaCore

/// The About window's content.
@MainActor
final class AboutView: NSView {
    static let width: CGFloat = 520, minimumHeight: CGFloat = 0 // sizes to its content
    private static let margin: CGFloat = 24, titlebar: CGFloat = 28

    private lazy var copyButton: NSButton = {
        let button = NSButton(
            title: String(localized: "Copy Version Info"), target: self, action: #selector(copyVersionInfo))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Theme.body
        return button
    }()
    private var copyReset: Task<Void, Never>?
    /// Where Copy Version Info writes; tests pass a private pasteboard.
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.minimumHeight))
        build()
    }
    @available(*, unavailable, message: "AboutView is built in code")
    required init?(coder _: NSCoder) { fatalError("AboutView is built in code") }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.window.setFill()
        dirtyRect.fill()
    }

    private func build() {
        let header = makeHeader()
        let thisCopy = makeThisCopy()
        let links = makeLinks()
        // No heading over an empty column: without a domain there are no links to show.
        let columns = NSStackView(views: links.map { [thisCopy, $0] } ?? [thisCopy])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 14

        let footer = label("© 2026 Clever Mechanisms", font: Theme.caption, color: Theme.secondaryText)

        for view in [header, columns, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            header.topAnchor.constraint(equalTo: topAnchor, constant: Self.titlebar + 6),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.margin),
            columns.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            columns.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin),
            footer.topAnchor.constraint(equalTo: columns.bottomAnchor, constant: 18),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    /// Icon, name, version (build), one line.
    private func makeHeader() -> NSStackView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let name = label("Gitā", font: TextLines.system(22, weight: .bold), color: Theme.text)
        let version = label(
            String(localized: "Version \(AppInfo.version) (\(AppInfo.build))"), font: TextLines.system(13),
            color: Theme.secondaryText)
        version.isSelectable = true
        let tagline = NSTextField(
            wrappingLabelWithString: String(localized: "Your repositories, CI, deployments and agents in one window."))
        tagline.font = TextLines.system(13)
        tagline.textColor = Theme.text
        tagline.preferredMaxLayoutWidth = Self.width - 2 * Self.margin - 72 - 16
        let texts = stack([name, version, tagline], vertical: true, spacing: 3)
        texts.distribution = .fill
        // Every line keeps its full height (a wrapped tagline in German must grow the header, not squeeze the version).
        for line in [name, version, tagline] {
            line.setContentHuggingPriority(.required, for: .vertical)
            line.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        texts.setHuggingPriority(.required, for: .vertical) // exactly its lines; centred beside the 72 pt icon
        let header = stack([icon, texts], spacing: 16)
        header.alignment = .centerY
        return header
    }

    private func makeThisCopy() -> NSStackView {
        let grid = NSGridView(views: [
            [rowLabel(String(localized: "Version")), value("\(AppInfo.version) (\(AppInfo.build))")],
            [rowLabel(String(localized: "System")), value("\(AppInfo.system) · \(AppInfo.architecture)")],
        ])
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        // At least 56 pt; wider when the interface font or the language needs it.
        let labelWidth =
            (0..<grid.numberOfRows).compactMap {
                grid.cell(atColumnIndex: 0, rowIndex: $0).contentView?.fittingSize.width
            }.max() ?? 0
        grid.column(at: 0).width = max(56, ceil(labelWidth))
        grid.rowAlignment = .firstBaseline
        let thisCopy = stack(
            [sectionTitle(String(localized: "This copy")), grid, copyButton], vertical: true, spacing: 5)
        thisCopy.setCustomSpacing(8, after: grid)
        return thisCopy
    }

    /// Links to the product site, the GitHub repository, and the issue tracker.
    private func makeLinks() -> NSStackView? {
        var links: [NSView] = [sectionTitle(String(localized: "Links"))]
        if let home = Website.home, let host = Website.host {
            links.append(AboutLink(title: host, symbol: "globe", url: home))
        }
        if let repository = Website.repository {
            links.append(
                AboutLink(
                    title: Website.repositoryPath,
                    image: BrandMarks.image(.github, size: 12, color: Theme.accentText), url: repository))
        }
        if let issue = BugReport.url() {
            links.append(AboutLink(title: String(localized: "Report Bug"), symbol: "ladybug", url: issue))
        }
        // Rows on the same 19 pt pitch as "This copy", so each link lines up with the row beside it.
        guard links.count > 1 else { return nil }
        let linkColumn = stack(links, vertical: true, spacing: 4)
        linkColumn.setCustomSpacing(5, after: links[0])
        return linkColumn
    }

    @objc private func copyVersionInfo() {
        pasteboard.clearContents()
        pasteboard.setString(AppInfo.summary, forType: .string)
        copyButton.title = String(localized: "Copied")
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copyButton.title = String(localized: "Copy Version Info")
        }
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    private func sectionTitle(_ text: String) -> NSTextField {
        label(text, font: Theme.bodyEmphasis, color: Theme.secondaryText)
    }
    private func rowLabel(_ text: String) -> NSTextField { label(text, font: Theme.body, color: Theme.secondaryText) }
    private func value(_ text: String) -> NSTextField {
        let field = label(text, font: Theme.body, color: Theme.text)
        field.isSelectable = true
        return field
    }
    private func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        // Hug the content: beside a taller sibling a low-hugging stack could take any height (layout audit).
        stack.setHuggingPriority(.defaultHigh, for: vertical ? .vertical : .horizontal)
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        return stack
    }
}
