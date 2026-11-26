import AppKit

final class StorageWorkspaceListView: NSScrollView {
    init(rows: [StorageWorkspaceRow], inspect: @escaping (URL) -> Void) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        let document = Deck.document(in: self)
        let stack = Deck.vstack([], spacing: 10)
        Deck.pin(stack, in: document)
        let presenter = StoragePresenter()
        for row in rows {
            let name = Deck.label(row.name, font: Theme.bodyEmphasis)
            let size = Deck.label(presenter.formatBytes(row.totalBytes), font: Theme.mono)
            let badge = StorageSummaryBar.badge(
                String(localized: "\(presenter.formatBytes(row.reclaimableBytes)) reclaimable"))
            let button = ActionButton(title: String(localized: "Inspect")) { inspect(row.root) }
            let top = Deck.hstack([name, Deck.spacer(), size, badge, button])
            let worktrees =
                row.worktreeCount == 1
                ? String(localized: "1 worktree · \(row.root.path)")
                : String(localized: "\(row.worktreeCount) worktrees · \(row.root.path)")
            let caption = Deck.caption(worktrees)
            let track = FillView(color: Theme.control)
            let fill = FillView(color: Theme.accent)
            track.cornerRadius = 3
            fill.cornerRadius = 3
            track.addSubview(fill)
            fill.translatesAutoresizingMaskIntoConstraints = false
            let column = Deck.vstack([top, caption, track], spacing: 5)
            stack.addArrangedSubview(column)
            NSLayoutConstraint.activate([
                column.widthAnchor.constraint(equalTo: stack.widthAnchor),
                top.widthAnchor.constraint(equalTo: column.widthAnchor),
                track.widthAnchor.constraint(equalTo: column.widthAnchor),
                track.heightAnchor.constraint(equalToConstant: 5),
                fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
                fill.topAnchor.constraint(equalTo: track.topAnchor),
                fill.heightAnchor.constraint(equalTo: track.heightAnchor),
                fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: row.share),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageWorkspaceListView is built in code") }
}
