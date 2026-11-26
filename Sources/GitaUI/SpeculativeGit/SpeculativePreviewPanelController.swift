import AppKit
import GitaCore

final class SpeculativePreviewPanelController: NSViewController {
    let presenter: SpeculativePreviewPresenter
    var isHostedInSheet = false { didSet { if isViewLoaded { render() } } }
    var onStatusChange: ((SheetStatus) -> Void)?
    private let badge = ConflictRiskBadgeView()
    private let summary = Deck.label("", font: Theme.title)
    private let indicator = SpeculativeViews.spinner()
    private let list = SpeculativeList(id: "preview.steps", label: String(localized: "Steps and conflicted files"))
    private let editor = NSTextView()
    private let status = Deck.wrapping("", color: Theme.secondaryText)
    private let fileStatus = Deck.wrapping("", color: Theme.failure)
    private lazy var fileNotice = Deck.hstack([fileStatus, retryFile])
    private lazy var header = Deck.hstack([badge, summary, Deck.spacer(), indicator, refresh])
    private let separator = Deck.separator()
    private let split = NSSplitView()
    private let placeholder = NSView()
    private lazy var retry = SpeculativeViews.button(
        String(localized: "Retry"), symbol: "arrow.clockwise", id: "preview.retry"
    ) { [weak self] in self?.presenter.refresh() }
    private lazy var retryFile = SpeculativeViews.button(
        String(localized: "Retry"), symbol: "arrow.clockwise", id: "preview.retryFile"
    ) { [weak self] in
        guard let self, let step = presenter.selectedStep else { return }
        presenter.select(step: step, file: presenter.selectedFile)
    }
    private lazy var refresh = SpeculativeViews.button(
        String(localized: "Refresh"), symbol: "arrow.clockwise", id: "preview.refresh"
    ) { [weak self] in self?.presenter.refresh() }
    private lazy var emptyRefresh = SpeculativeViews.button(
        String(localized: "Refresh"), symbol: "arrow.clockwise", id: "preview.emptyRefresh"
    ) { [weak self] in self?.presenter.refresh() }
    private struct Entry {
        let step: Int
        let file: String?
        let row: SpeculativeList.Row
    }
    private var entries: [Entry] = []

    init(presenter: SpeculativePreviewPresenter) {
        self.presenter = presenter
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override func loadView() {
        view = ThemedBackgroundView()
        view.setAccessibilityIdentifier("speculative.preview.panel")
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(Style.scroll(list))
        split.addArrangedSubview(
            SpeculativeViews.preview(
                editor, id: "preview.excerpt",
                label: String(localized: "Dry-run conflict preview")))
        for (index, pane) in split.arrangedSubviews.enumerated() {
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: index == 0 ? 220 : 280).isActive = true
            split.setHoldingPriority(.init(index == 0 ? 260 : 250), forSubviewAt: index)
        }
        let center = Deck.vstack([status, retry, emptyRefresh], spacing: 8)
        center.alignment = .centerX
        placeholder.addSubview(center)
        center.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),
            center.widthAnchor.constraint(lessThanOrEqualTo: placeholder.widthAnchor, constant: -16),
        ])
        let body = NSView()
        Deck.pin(split, in: body)
        Deck.pin(placeholder, in: body)
        let column = SpeculativeViews.column([header, separator, body, fileNotice])
        Style.fill(column, in: view, inset: 12)
        list.onSelect = { [weak self] index in
            guard let self, entries.indices.contains(index) else { return }
            presenter.select(step: entries[index].step, file: entries[index].file)
        }
        badge.onPress = { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(list)
        }
        presenter.onChange = { [weak self] in self?.render() }
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if case .idle = presenter.state { presenter.refresh() }
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        presenter.cancel()
    }
    override func cancelOperation(_ sender: Any?) {
        if let window = view.window, let parent = window.sheetParent {
            parent.endSheet(window, returnCode: .cancel)
        } else {
            view.window?.performClose(sender)
        }
    }

    private func render() {
        header.isHidden = isHostedInSheet
        separator.isHidden = isHostedInSheet
        status.isHidden = isHostedInSheet
        SpeculativeViews.show(indicator, busy: !isHostedInSheet && presenter.showsLoadingIndicator)
        fileNotice.isHidden = true
        emptyRefresh.isHidden = true
        retry.isHidden = true
        retryFile.isHidden = true
        refresh.isHidden = false
        split.isHidden = true
        placeholder.isHidden = false
        status.textColor = Theme.secondaryText
        summary.font = Theme.title
        summary.stringValue = String(localized: "Conflict preview")
        switch presenter.state {
        case .idle:
            emptyRefresh.isHidden = false
            refresh.isHidden = true
            badge.badgeState = .idle
            status.stringValue = String(localized: "Refresh to preview these changes.")
        case .loading:
            badge.badgeState = .checking
            status.stringValue = String(localized: "Checking changes…")
        case .failed(let message):
            badge.badgeState = .unavailable(message)
            status.stringValue = message
            status.textColor = Theme.failure
            retry.isHidden = false
            refresh.isHidden = true
        case .loaded(let content): display(content)
        }
        summary.toolTip = summary.stringValue
        if isHostedInSheet { onStatusChange?(sheetStatus) }
    }

    private var sheetStatus: SheetStatus {
        if case .failed(let message) = presenter.state { return .init(message: message, isError: true) }
        if case .failed(let message) = presenter.filePreview { return .init(message: message, isError: true) }
        if case .loading = presenter.filePreview {
            return .init(message: String(localized: "Loading file preview…"), isBusy: true)
        }
        if case .loading = presenter.state { return .init(message: status.stringValue, isBusy: true) }
        let message =
            split.isHidden
            ? status.stringValue : String(localized: "\(summary.stringValue) · \(badge.badgeState.title)")
        return .init(message: message)
    }

    private func display(_ content: SpeculativePreviewContent) {
        let steps = content.steps
        let conflicts = steps.filter { $0.outcome.risk == .conflict }
        let warnings = steps.filter { $0.outcome.risk == .warning }
        if !conflicts.isEmpty {
            badge.badgeState = .conflict(count: conflicts.count, files: conflicts.flatMap(\.outcome.conflictingFiles))
        } else if !warnings.isEmpty {
            badge.badgeState = .warning(
                count: warnings.count, detail: warnings.map(\.outcome.descriptionText).joined(separator: "\n"))
        } else {
            badge.badgeState = .clean
        }
        guard !steps.isEmpty else {
            emptyRefresh.isHidden = false
            refresh.isHidden = true
            status.stringValue = String(localized: "The plan has no steps to preview.")
            return
        }
        split.isHidden = false
        placeholder.isHidden = true
        summary.font = steps.count == 1 && steps[0].mono ? Theme.mono : Theme.title
        summary.stringValue = steps.count == 1 ? steps[0].title : String(localized: "\(steps.count) rebase steps")
        entries = steps.enumerated().flatMap { index, step in
            let title = String(localized: "\(step.title) · \(step.outcome.risk.title)")
            let row = SpeculativeList.Row(
                id: String(index), title: title, symbol: step.outcome.risk.symbol,
                tooltip: step.outcome.descriptionText, mono: step.mono)
            return [Entry(step: index, file: nil, row: row)]
                + step.outcome.conflictingFiles.map { file in
                    Entry(
                        step: index, file: file,
                        row: .init(id: "\(index)/\(file)", title: file, symbol: "doc.text", mono: true))
                }
        }
        let index = entries.firstIndex { $0.step == presenter.selectedStep && $0.file == presenter.selectedFile }
        list.display(entries.map(\.row), selection: index)
        displayExcerpt(steps: steps)
    }

    private func displayExcerpt(steps: [SpeculativePreviewContent.Step]) {
        switch presenter.filePreview {
        case .loaded(let preview):
            let size = ByteCountFormatter.string(fromByteCount: Int64(preview.totalByteCount), countStyle: .file)
            let footer = preview.truncated ? String(localized: "\n\nExcerpt from \(size).") : ""
            editor.textStorage?.setAttributedString(DiffHighlightFormatter.formatted(preview.excerpt + footer))
        case .loading:
            setProse(isHostedInSheet ? "" : String(localized: "Loading file preview…"))
        case .failed(let error):
            retryFile.isHidden = false
            refresh.isHidden = true
            fileNotice.isHidden = false
            fileStatus.isHidden = isHostedInSheet
            fileStatus.stringValue = error
            editor.string = ""
        case .idle:
            let message =
                presenter.selectedStep.map { steps[$0].outcome.descriptionText }
                ?? String(localized: "Select a step to see its outcome.")
            setProse(message)
        }
    }

    private func setProse(_ text: String) {
        editor.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: Theme.body, .foregroundColor: Theme.secondaryText]))
    }
}
