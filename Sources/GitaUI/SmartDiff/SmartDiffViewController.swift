import AppKit
import GitaCore

@MainActor
private final class SmartDiffTable: NSTableView {
    var activate: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if KeyPress.isActivation(event), selectedRow >= 0 { activate?(selectedRow) } else { super.keyDown(with: event) }
    }
}

@MainActor
final class SmartDiffViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    let presenter: SmartDiffPresenter
    var onJumpToFileLine: ((String, Int) -> Void)?
    private(set) lazy var toolbar = SmartDiffToolbarView(presenter: presenter)
    private let table = SmartDiffTable()
    private let container = ThemedBackgroundView()
    private lazy var scroll = Style.scroll(table)
    private let spinner = NSProgressIndicator()
    private var delay: Task<Void, Never>?
    private var rows: [SmartDiffRow] = []

    init(presenter: SmartDiffPresenter = SmartDiffPresenter()) {
        self.presenter = presenter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(presenter:)") }

    override func loadView() {
        view = ThemedBackgroundView()
        view.smartDiffAccessibility(String(localized: "Smart diff"), "diff.view")
        let stack = Deck.vstack([toolbar, container], spacing: 0)
        Deck.pin(stack, in: view)
        for child in [toolbar as NSView, container] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        configureTable()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.usesThreadedAnimation = false
        presenter.onChange = { [weak self] state in self?.render(state) }
        render(presenter.state)
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: .init("content"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 21
        table.intercellSpacing = .zero
        table.backgroundColor = Theme.window
        table.focusRingType = .default
        table.delegate = self
        table.dataSource = self
        table.activate = { [weak self] row in self?.activate(row) }
        table.smartDiffAccessibility(String(localized: "Diff lines and changes"), "diff.table")
    }

    private func render(_ state: SmartDiffState) {
        delay?.cancel()
        spinner.stopAnimation(nil)
        let keepScroll: Bool
        if case .loaded(let snapshot) = state { keepScroll = !snapshot.displayRows.isEmpty } else { keepScroll = false }
        for child in container.subviews where !keepScroll || child !== scroll { child.removeFromSuperview() }
        toolbar.render(state)
        rows = []
        switch state {
        case .idle: center(Deck.caption(String(localized: "Select a file to review its changes")))
        case .empty: center(Deck.caption(String(localized: "No changes to show")))
        case .loading:
            showDelayedSpinner()
        case .failed(let reason):
            let label = Deck.wrapping(reason, color: Theme.failure)
            let retry = SmartDiffControls.button(String(localized: "Retry"), id: "diff.retry") { [weak self] in
                self?.presenter.retry()
            }
            center(Deck.vstack([label, retry]))
        case .loaded(let snapshot):
            rows = snapshot.displayRows
            if rows.isEmpty {
                center(Deck.caption(String(localized: "No structured changes")))
            } else {
                if scroll.superview == nil { Deck.pin(scroll, in: container) }
                table.reloadData()
            }
        }
    }

    private func showDelayedSpinner() {
        delay = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.center(self.spinner)
            self.spinner.startAnimation(nil)
        }
    }

    private func center(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            child.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            child.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor),
        ])
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DeckTableRowView.reused(in: tableView, id: .init("smartdiff.diff.row"))
    }

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row), case .diffLine = rows[row] else { return 24 }
        return 21
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let activate: () -> Void = { [weak self] in self?.activate(row) }
        switch rows[row] {
        case .collapsedNoisePill(let run):
            let cell =
                tableView.makeView(withIdentifier: SmartDiffPillCell.cellID, owner: nil) as? SmartDiffPillCell
                ?? SmartDiffPillCell()
            cell.configure(title: run.summaryText, row: row, activate: activate)
            return cell
        case .structuredEntry(let entry):
            let cell =
                tableView.makeView(withIdentifier: SmartDiffStructuredCell.cellID, owner: nil)
                as? SmartDiffStructuredCell ?? SmartDiffStructuredCell()
            cell.configure(entry)
            return cell
        case .diffLine(let line, let role):
            let cell = tableView.makeView(withIdentifier: DiffView.cellID, owner: nil) as? DiffCell ?? DiffCell()
            cell.identifier = DiffView.cellID
            cell.line = line
            cell.fontSize = DiffCell.Metrics.fontSize
            cell.configureMove(role, row: row, jump: activate)
            return cell
        }
    }

    private func activate(_ row: Int) {
        guard rows.indices.contains(row), case .loaded(let snapshot) = presenter.state else { return }
        switch rows[row] {
        case .collapsedNoisePill(let run):
            presenter.toggleNoiseRun(hunkIndices: run.hunkIndices)
            if case .loaded(let updated) = presenter.state { reveal(run.anchorLineIndex, snapshot: updated) }
        case .diffLine(_, let role?):
            let id: String
            switch role {
            case .movedFrom(let match, _, _), .movedTo(let match, _, _): id = match
            }
            guard let index = snapshot.documentIndices[row],
                let target = presenter.jumpTarget(forMoveID: id, fromLineIndex: index)
            else { return }
            if target.filePath == snapshot.filePath {
                reveal(target.lineIndex, snapshot: snapshot)
            } else {
                onJumpToFileLine?(target.filePath, target.lineIndex)
            }
        default: break
        }
    }

    private func reveal(_ index: Int, snapshot: SmartDiffSnapshot) {
        if let row = snapshot.documentIndices.first(where: { $0.value == index })?.key {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            scrollToRow(row)
            view.window?.makeFirstResponder(table)
        } else if snapshot.document.lines.indices.contains(index), let hunk = snapshot.document.lines[index].hunkIndex {
            presenter.toggleNoiseRun(hunkIndices: [hunk])
            if case .loaded(let updated) = presenter.state { reveal(index, snapshot: updated) }
        }
    }

    private func scrollToRow(_ row: Int) {
        let clip = scroll.contentView
        let target = table.rect(ofRow: row)
        guard !clip.bounds.contains(target) else { return }
        if Deck.reduceMotion {
            table.scrollRowToVisible(row)
            return
        }
        var visible = clip.bounds
        visible.origin.y = target.minY < visible.minY ? target.minY : target.maxY - visible.height
        let origin = clip.constrainBoundsRect(visible).origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            clip.animator().setBoundsOrigin(origin)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard case .loaded(let snapshot) = presenter.state, !snapshot.expandedNoiseHunks.isEmpty else {
            nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
            return
        }
        presenter.toggleNoiseRun(hunkIndices: Array(snapshot.expandedNoiseHunks))
    }
    deinit { delay?.cancel() }
}
