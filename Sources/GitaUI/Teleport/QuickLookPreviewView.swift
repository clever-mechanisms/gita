import AppKit
import GitaCore

@MainActor
public final class QuickLookPreviewView: NSView {
    public var onClose: (() -> Void)?
    public var onRetry: (() -> Void)?
    public var onOpenFull: (() -> Void)?
    var onNavigate: ((QuickLookNavigationDirection) -> Void)?
    private let surface = TeleportControls.surface(Theme.window, radius: 12)
    private let stack = Deck.vstack([], spacing: 0)
    private weak var spinner: NSProgressIndicator?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Quick Look preview"))
        setAccessibilityIdentifier("teleport.quickLook.preview")
        Deck.pin(surface, in: self)
        Deck.pin(stack, in: surface, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        guard KeyPress.isPlain(event) else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case KeyPress.space: onClose?()
        case KeyPress.upArrow: onNavigate?(.previous)
        case KeyPress.downArrow: onNavigate?(.next)
        case KeyPress.returnKey, KeyPress.keypadEnter: onOpenFull?()
        default: interpretKeyEvents([event])
        }
    }

    func revealSpinner() {
        if let spinner { TeleportControls.reveal(spinner) }
    }

    public func display(_ state: QuickLookLoadState) {
        if let focused = window?.firstResponder as? NSView, focused.isDescendant(of: stack) {
            window?.makeFirstResponder(self)
        }
        TeleportControls.clear(stack)
        switch state {
        case .idle: return
        case .loaded(let content):
            header(content.target, content: content)
            if content.statSummary != nil || !content.files.isEmpty || content.omittedFileCount > 0 {
                fileStrip(content)
            }
            if content.isBinary {
                centered([
                    TeleportControls.icon("doc.fill", size: 20, color: Theme.secondaryText),
                    Deck.caption(String(localized: "Binary file, no text preview")), openFullButton(),
                ])
            } else {
                append(QuickLookDiffView.make(content.diffExcerpt))
                footer(content.diffExcerpt)
            }
        case .loading(let target, let showsSpinner):
            header(target)
            let message = String(localized: "Loading preview…")
            let spinner = TeleportControls.spinner(message, id: "teleport.quickLook.spinner")
            self.spinner = spinner
            centered([TeleportControls.spinnerSlot(spinner), Deck.caption(message)])
            if showsSpinner { revealSpinner() }
            footer(nil)
        case .empty(let target, let message):
            header(target)
            centered([Deck.caption(message)])
            footer(nil)
        case .failed(let target, let message):
            header(target)
            let retry = TeleportControls.button(String(localized: "Retry"), id: "teleport.quickLook.retry") {
                [weak self] in self?.onRetry?()
            }
            centered([
                TeleportControls.icon("exclamationmark.triangle.fill", size: 20, color: Theme.failure),
                Deck.wrapping(message),
                retry,
            ])
            footer(nil)
        }
    }

    private func header(_ target: QuickLookTarget, content: QuickLookPreviewContent? = nil) {
        let info = QuickLookHeading(target, content: content)
        let title = Deck.label(info.title, font: Theme.title)
        title.toolTip = info.title
        title.setAccessibilityIdentifier("teleport.quickLook.title")
        let subtitle = Deck.label(info.reference, font: Theme.mono, color: Theme.secondaryText)
        let byline = [info.author, info.date.map { DeckFormat.relative($0) }].compactMap { $0 }.joined(separator: " · ")
        let detail = Deck.hstack([subtitle, Deck.caption(byline)], spacing: 8)
        let column = Deck.vstack([title, detail])
        if !info.badges.isEmpty {
            column.addArrangedSubview(
                Deck.hstack(
                    info.badges.map {
                        TeleportControls.pill(
                            $0.title, color: Theme.color(for: $0.state), symbol: Style.stateSymbol($0.state))
                    }, spacing: 4))
        }
        let close = TeleportControls.button(
            String(localized: "Close Preview"), symbol: "xmark", iconOnly: true,
            background: .hover, id: "teleport.quickLook.close"
        ) { [weak self] in self?.onClose?() }
        close.toolTip = String(localized: "Close preview (Escape or Space)")
        append(
            padded(
                Deck.hstack([
                    TeleportControls.icon(info.symbol, size: 20, color: Theme.working), column, Deck.spacer(), close,
                ])))
    }

    private func fileStrip(_ content: QuickLookPreviewContent) {
        let rows = Deck.vstack([], spacing: 4)
        if let summary = content.statSummary {
            rows.addArrangedSubview(Deck.label(summary, font: Theme.captionEmphasis))
        }
        for file in content.files {
            let label = Deck.label(file.path, font: Theme.mono, color: Theme.secondaryText)
            label.toolTip = file.path
            rows.addArrangedSubview(label)
            label.widthAnchor.constraint(lessThanOrEqualTo: rows.widthAnchor).isActive = true
        }
        if content.omittedFileCount > 0 {
            let omitted =
                content.omittedFileCount == 1
                ? String(localized: "+1 more file") : String(localized: "+\(content.omittedFileCount) more files")
            rows.addArrangedSubview(Deck.caption(omitted))
        }
        let scroll = Style.scroll(NSView())
        scroll.backgroundColor = Theme.inset
        Deck.pin(rows, in: Deck.document(in: scroll), insets: TeleportControls.cardInsets)
        scroll.heightAnchor.constraint(equalToConstant: min(96, CGFloat(rows.arrangedSubviews.count) * 20 + 12))
            .isActive = true
        scroll.setAccessibilityLabel(String(localized: "Changed files"))
        scroll.setAccessibilityIdentifier("teleport.quickLook.files")
        append(scroll)
    }

    private func centered(_ views: [NSView]) {
        let area = NSView()
        let content = Deck.vstack(views, spacing: 8)
        content.alignment = .centerX
        content.translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            content.widthAnchor.constraint(lessThanOrEqualTo: area.widthAnchor, constant: -32),
        ])
        append(area)
    }

    private func footer(_ excerpt: QuickLookDiffExcerpt?) {
        append(Deck.separator())
        let hint: String
        if let excerpt, excerpt.isTruncated {
            hint =
                excerpt.totalLineCount == 1
                ? String(localized: "Showing \(excerpt.lines.count) of 1 line")
                : String(localized: "Showing \(excerpt.lines.count) of \(excerpt.totalLineCount) lines")
        } else {
            hint = String(localized: "↑↓ Navigate    Space / ⎋ Close")
        }
        append(padded(Deck.hstack([Deck.caption(hint), Deck.spacer(), openFullButton()])))
    }

    private func openFullButton() -> PartsButton {
        TeleportControls.button(
            String(localized: "Open in Main Window"), symbol: "return",
            background: .accent, id: "teleport.quickLook.openFull"
        ) { [weak self] in self?.onOpenFull?() }
    }

    private func padded(_ row: NSView) -> NSView {
        let view = NSView()
        Deck.pin(row, in: view, insets: TeleportControls.cardInsets)
        return view
    }

    private func append(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

private struct QuickLookHeading {
    var title: String
    var reference: String
    var symbol: String
    var author: String?
    var date: Date?
    var badges: [QuickLookBadge] = []

    init(_ target: QuickLookTarget, content: QuickLookPreviewContent?) {
        switch target {
        case .commit(_, let sha, let hint):
            title = hint?.subject ?? String(localized: "Commit")
            reference = String(sha.prefix(12))
            symbol = "point.topleft.down.to.point.bottomright.curvepath"
            author = hint?.author
            date = hint?.date
            badges = hint?.badges ?? []
        case .stash(_, let ref, let message):
            title = message ?? String(localized: "Stash")
            reference = ref
            symbol = "archivebox"
        case .changedFile(_, let path, let staged, _, let sha):
            title = path
            reference = sha ?? (staged ? String(localized: "Staged") : String(localized: "Working tree"))
            symbol = "doc.text"
        }
        if let content {
            title = content.title
            reference = content.subtitle
            author = content.author
            date = content.date
            badges = content.pills
        }
    }
}
