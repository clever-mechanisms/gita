import AppKit
import GitaCore

@MainActor
final class AgentFlightRecorderViewController: NSViewController {
    let presenter: FlightRecorderPresenter
    let scrubber = FlightTurnScrubberView()
    private let recording = NSSwitch()
    private let detail = Deck.hstack([])
    private let strip = FillView(color: Theme.inset)
    private let refreshSpinner = DelayedSpinnerController()
    private let feedback = Deck.caption("")
    private lazy var comparison = AgentControlUI.popup(
        String(localized: "Compare turn"), "flight.comparison",
        target: self, action: #selector(compare))
    private lazy var pane = FlightDiffPane(presenter)
    private lazy var body = AgentControlBody(content: pane, id: "flight.body")
    private lazy var snapshot = AgentControlUI.button(
        String(localized: "Snapshot Now"), "flight.capture", style: .accent
    ) {
        [weak self] in self?.presenter.captureManualSnapshot()
    }
    private lazy var clear = AgentControlUI.button(String(localized: "Clear"), "flight.clear") {
        [weak self] in self?.presenter.clearSnapshots(on: self?.view.window)
    }
    private lazy var restore = AgentControlUI.button(
        String(localized: "Restore Turn"), "flight.restore"
    ) {
        [weak self] in self?.presenter.restoreSelectedTurn(on: self?.view.window)
    }

    init(presenter: FlightRecorderPresenter) {
        self.presenter = presenter
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Flight Recorder")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic controller") }

    override func loadView() {
        let label = String(localized: "Recording")
        recording.setAccessibilityLabel(label)
        AgentControlUI.identify(recording, "flight.recording")
        recording.target = self
        recording.action = #selector(toggle)
        let header = Deck.hstack([
            AgentControlUI.label(label, font: Theme.title), recording, refreshSpinner.indicator, Deck.spacer(),
            snapshot, clear, restore,
        ])
        strip.cornerRadius = 8
        let detailsRow = Deck.hstack([detail, Deck.spacer(), comparison])
        Deck.pin(detailsRow, in: strip, insets: NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8))
        let surface = AgentControlSurface(
            [header, Deck.separator(), scrubber, strip, body, feedback], primary: snapshot, id: "flight.root")
        view = surface
        recording.nextKeyView = snapshot
        snapshot.nextKeyView = clear
        clear.nextKeyView = restore
        wireContentKeyLoop()
        scrubber.onSelect = { [weak self] in self?.presenter.selectTurn(index: $0) }
        presenter.shouldReloadAfterWrite = { [weak self] in self?.view.window?.isVisible == true }
        presenter.onStateChange = { [weak self] in self?.render() }
        render()
    }

    private func wireContentKeyLoop() {
        restore.nextKeyView = scrubber
        scrubber.nextKeyView = comparison
        comparison.nextKeyView = pane.files.table
        pane.diff.table.nextKeyView = recording
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        presenter.load()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        presenter.cancel()
        body.spinner.stop()
        refreshSpinner.stop()
    }

    @objc private func toggle() { presenter.setEnabled(recording.state == .on) }

    private func render() {
        let state = presenter.state
        let loaded = isLoaded(state)
        recording.state = presenter.isEnabled ? .on : .off
        recording.isEnabled = canToggleRecording(state)
        restore.isEnabled = loaded
        clear.isEnabled = loaded
        snapshot.isEnabled = loaded || state == .empty
        let refreshing = isBusyRefreshing(state)
        if refreshing { refreshSpinner.start() } else { refreshSpinner.stop() }
        let showsTurn = refreshing || loaded || (state == .loading && presenter.selectedTurn != nil)
        strip.isHidden = !showsTurn
        scrubber.isHidden = !showsTurn
        if showsTurn {
            scrubber.update(turns: presenter.turns, selected: presenter.selectedTurnIndex)
            showDetails()
        }
        feedback.stringValue = presenter.feedback
        feedback.isHidden = presenter.feedback.isEmpty
        renderBody(state)
    }

    private func isLoaded(_ state: FlightRecorderState) -> Bool {
        if case .loaded = state { return true }
        return false
    }

    private func canToggleRecording(_ state: FlightRecorderState) -> Bool {
        switch state {
        case .loaded, .disabled, .empty, .idle, .failed: true
        case .loading, .writing, .restoring: false
        }
    }

    private func isBusyRefreshing(_ state: FlightRecorderState) -> Bool {
        guard presenter.diff != nil else { return false }
        switch state {
        case .loading, .writing: return true
        default: return false
        }
    }

    private func renderBody(_ state: FlightRecorderState) {
        switch state {
        case .idle: message(String(localized: "Open the snapshot history."), String(localized: "Load History"))
        case .loading:
            if presenter.diff != nil {
                body.showContent()
            } else {
                body.show(String(localized: "Loading snapshots…"), busy: true)
            }
        case .writing(let kind):
            if presenter.diff != nil, kind == .capturing {
                body.showContent()
            } else {
                body.show(Self.writingMessage(kind), busy: true)
            }
        case .restoring: body.show(String(localized: "Restoring the working tree…"), busy: true)
        case .disabled:
            message(String(localized: "Recording is off for this repository."), String(localized: "Enable Recording"))
        case .empty:
            message(
                String(localized: "Capture a snapshot to record the first turn."), String(localized: "Capture Snapshot")
            )
        case .failed(let reason): message(reason, String(localized: "Retry"), failed: true)
        case .loaded:
            wireContentKeyLoop()
            pane.render()
            body.showContent()
        }
    }

    static func writingMessage(_ kind: FlightWriteKind) -> String {
        switch kind {
        case .enabling: String(localized: "Enabling recording…")
        case .disabling: String(localized: "Disabling recording…")
        case .capturing: String(localized: "Capturing snapshot…")
        case .clearing: String(localized: "Clearing snapshots…")
        }
    }

    private func message(_ text: String, _ action: String, failed: Bool = false) {
        let button = AgentControlUI.button(action, "flight.stateAction") { [weak self] in
            guard let self else { return }
            switch self.presenter.state {
            case .disabled: self.presenter.setEnabled(true)
            case .empty: self.presenter.captureManualSnapshot()
            default: self.presenter.load()
            }
        }
        restore.nextKeyView = button
        button.nextKeyView = recording
        body.show(text, failed: failed, button: button)
    }

    private func showDetails() {
        guard let turn = presenter.selectedTurn else { return }
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        detail.addArrangedSubview(
            AgentControlUI.label(String(localized: "Turn \(turn.sequence)"), font: Theme.bodyEmphasis))
        if !turn.label.isEmpty, turn.label != "Turn \(turn.sequence)" {
            detail.addArrangedSubview(AgentControlUI.label(turn.label, font: Theme.caption))
        }
        detail.addArrangedSubview(AgentControlFormatting.trigger(turn.trigger).view)
        if let tool = turn.tool { detail.addArrangedSubview(AgentControlUI.label(tool.displayName)) }
        let age = DeckFormat.relative(turn.createdAt)
        detail.addArrangedSubview(
            AgentControlUI.label(
                String(localized: "\(age) · \(AgentControlFormatting.files(turn.changedFileCount))"),
                font: Theme.caption, color: Theme.secondaryText))
        comparison.removeAllItems()
        comparison.addItems(withTitles: [String(localized: "vs Previous Turn"), String(localized: "vs Working Tree")])
        for other in presenter.turns where other.id != turn.id {
            let item = NSMenuItem(
                title: String(localized: "vs Turn \(other.sequence) · \(DeckFormat.relative(other.createdAt))"),
                action: nil, keyEquivalent: "")
            item.representedObject = other.id
            comparison.menu?.addItem(item)
        }
        selectComparisonItem()
    }

    private func selectComparisonItem() {
        let mode = presenter.comparison
        if mode == .previous, presenter.effectiveComparison == .workingTree {
            comparison.item(at: 0)?.title = String(localized: "vs Previous Turn (using working tree)")
        }
        switch mode {
        case .previous: comparison.selectItem(at: 0)
        case .workingTree: comparison.selectItem(at: 1)
        case .turn(let id):
            let index = comparison.indexOfItem(withRepresentedObject: id)
            if index >= 0 {
                comparison.selectItem(at: index)
            } else {
                comparison.selectItem(at: presenter.effectiveComparison == .previous ? 0 : 1)
            }
        }
    }

    @objc private func compare() {
        if comparison.indexOfSelectedItem == 0 {
            presenter.selectPrevious()
        } else {
            presenter.selectComparison(toSnapshotID: comparison.selectedItem?.representedObject as? String)
        }
    }
}
