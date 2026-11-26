import AppKit

enum StorageWorkspaceListState: Equatable {
    case idle
    case scanning(completed: Int, total: Int, rows: [StorageWorkspaceRow], failureMessage: String?)
    case loaded(rows: [StorageWorkspaceRow], failureMessage: String?)
    case failed(String)

    var rows: [StorageWorkspaceRow] {
        switch self {
        case .scanning(_, _, let rows, _), .loaded(let rows, _): rows
        case .idle, .failed: []
        }
    }

    var statusMessage: String? {
        if case .scanning(let completed, let total, _, _) = self {
            return String(localized: "Scanned \(completed) of \(total) repositories…")
        }
        return nil
    }

    var failureMessage: String? {
        switch self {
        case .scanning(_, _, _, let message), .loaded(_, let message): message
        case .failed(let message): message
        case .idle: nil
        }
    }
}

@MainActor
final class StorageWorkspaceListView: NSScrollView {
    init(
        state: StorageWorkspaceListState, refresh: @escaping () -> Void, inspect: @escaping (URL) -> Void
    ) {
        super.init(frame: .zero)
        let document = StorageStyle.configureScrollView(self)
        let stack = Deck.vstack([], spacing: 14)
        Deck.pin(stack, in: document, insets: NSEdgeInsets(top: 16, left: 18, bottom: 18, right: 18))

        let presenter = StoragePresenter()
        let rows = state.rows
        let summaryCard = makeSummaryCard(
            rows: rows, statusMessage: state.statusMessage, presenter: presenter, refresh: refresh)
        StorageStyle.addFullWidth(summaryCard, to: stack)

        if let failureMessage = state.failureMessage, !failureMessage.isEmpty,
            let banner = StorageStyle.banner(.failed(failureMessage))
        {
            StorageStyle.addFullWidth(banner, to: stack)
        }

        if rows.isEmpty {
            let emptyCard = StorageStyle.card(cornerRadius: 10)
            let caption = Deck.caption(state.statusMessage ?? String(localized: "No repositories in this workspace."))
            Deck.pin(caption, in: emptyCard, insets: NSEdgeInsets(top: 20, left: 16, bottom: 20, right: 16))
            StorageStyle.addFullWidth(emptyCard, to: stack)
            return
        }

        StorageStyle.addFullWidth(makeRankedListCard(rows: rows, presenter: presenter, inspect: inspect), to: stack)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageWorkspaceListView is built in code") }

    private func makeSummaryCard(
        rows: [StorageWorkspaceRow], statusMessage: String?, presenter: StoragePresenter, refresh: @escaping () -> Void
    ) -> NSView {
        let card = StorageStyle.card(cornerRadius: 10)
        let totalBytes = rows.reduce(UInt64(0)) { $0 + $1.totalBytes }
        let reclaimableBytes = rows.reduce(UInt64(0)) { $0 + $1.reclaimableBytes }
        let subtitle =
            statusMessage
            ?? summarySubtitle(count: rows.count, reclaimableBytes: reclaimableBytes, presenter: presenter)
        let refreshButton = StorageStyle.actionButton(
            String(localized: "Refresh"), symbol: "arrow.clockwise", style: .quiet, onClick: refresh)
        let header = StorageStyle.heroHeader(
            symbol: "square.stack.3d.up", title: String(localized: "All Repositories"),
            heroMetric: presenter.formatBytes(totalBytes), subtitle: subtitle, controls: [refreshButton])
        Deck.pin(header, in: card, insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        return card
    }

    private func summarySubtitle(count: Int, reclaimableBytes: UInt64, presenter: StoragePresenter) -> String {
        let repos = count == 1 ? String(localized: "1 repository") : String(localized: "\(count) repositories")
        guard reclaimableBytes > 0 else { return repos }
        let reclaimable = presenter.formatBytes(reclaimableBytes)
        return String(localized: "\(repos) · \(reclaimable) reclaimable")
    }

    private func makeRankedListCard(
        rows: [StorageWorkspaceRow], presenter: StoragePresenter, inspect: @escaping (URL) -> Void
    ) -> NSView {
        let card = StorageStyle.card(cornerRadius: 10)
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 9
        clip.layer?.masksToBounds = true
        let listStack = Deck.vstack([], spacing: 0)
        Deck.pin(listStack, in: clip)
        Deck.pin(clip, in: card, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        for (index, row) in rows.enumerated() {
            if index > 0 { StorageStyle.addFullWidth(Deck.separator(), to: listStack) }
            StorageStyle.addFullWidth(
                WorkspaceRepositoryRow(row: row, presenter: presenter) { inspect(row.root) }, to: listStack)
        }
        return card
    }
}

@MainActor
private final class WorkspaceRepositoryRow: NSControl {
    private let onPress: () -> Void
    private var hovering = false

    init(row: StorageWorkspaceRow, presenter: StoragePresenter, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        focusRingType = .default

        let icon = StorageStyle.iconBadge(
            "internaldrive.fill", tint: Theme.accent, boxSize: 28, symbolSize: 13, cornerRadius: 7)
        let name = Deck.label(row.name, font: Theme.bodyEmphasis)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let abbreviatedPath =
            row.root.path.hasPrefix(home) ? "~" + row.root.path.dropFirst(home.count) : row.root.path
        let checkouts =
            row.worktreeCount == 1
            ? String(localized: "1 checkout · \(abbreviatedPath)")
            : String(localized: "\(row.worktreeCount) checkouts · \(abbreviatedPath)")
        let caption = Deck.caption(checkouts)
        caption.lineBreakMode = .byTruncatingMiddle
        let textColumn = Deck.vstack([name, caption], spacing: 2)

        var trailing = [NSView]()
        if row.reclaimableBytes > 0 {
            trailing.append(StorageStyle.reclaimablePill(row.reclaimableBytes, presenter: presenter))
        }
        trailing.append(StorageStyle.proportionBar(fraction: row.share, tint: Theme.accent, width: 64, height: 5))
        let size = Deck.label(
            presenter.formatBytes(row.totalBytes),
            font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), color: Theme.text)
        size.alignment = .right
        size.translatesAutoresizingMaskIntoConstraints = false
        size.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        trailing.append(size)
        let chevron = Deck.icon("chevron.right", size: 11, weight: .semibold, color: Theme.tertiaryText)
        chevron.setAccessibilityElement(false)
        trailing.append(chevron)

        let content = Deck.hstack([icon, textColumn, Deck.spacer()] + trailing, spacing: 10)
        Deck.pin(content, in: self, insets: NSEdgeInsets(top: 11, left: 14, bottom: 11, right: 14))
        configureAccessibility(row: row, presenter: presenter)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("WorkspaceRepositoryRow is built in code") }

    private func configureAccessibility(row: StorageWorkspaceRow, presenter: StoragePresenter) {
        let total = presenter.formatBytes(row.totalBytes)
        let checkouts =
            row.worktreeCount == 1
            ? String(localized: "1 checkout")
            : String(localized: "\(row.worktreeCount) checkouts")
        var parts = [row.name, total, checkouts]
        if row.reclaimableBytes > 0 {
            let reclaimable = presenter.formatBytes(row.reclaimableBytes)
            parts.append(String(localized: "\(reclaimable) reclaimable"))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(parts.joined(separator: ", "))
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }

    override func drawFocusRingMask() { bounds.insetBy(dx: 2, dy: 2).fill() }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.control.withAlphaComponent(0.55).setFill()
            dirtyRect.fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        replaceHoverTrackingArea()
    }

    override func mouseEntered(with _: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress()
    }

    override func keyDown(with event: NSEvent) {
        if KeyPress.isActivation(event) { onPress() } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress()
        return true
    }
}
