import AppKit
import GitaCore

@MainActor
final class SmartDiffToolbarView: NSView {
    private let presenter: SmartDiffPresenter
    private lazy var noise = SmartDiffControls.button(
        String(localized: "Noise filter"), id: "toolbar.noise",
        symbol: "line.3.horizontal.decrease"
    ) { [weak self] in
        self?.presenter.toggleNoiseFilter()
    }
    private lazy var moves = SmartDiffControls.button(
        String(localized: "Moves"), id: "toolbar.moves",
        symbol: "arrow.left.arrow.right"
    ) { [weak self] in
        self?.presenter.toggleMoveDetection()
    }
    private lazy var structured = SmartDiffControls.button(
        String(localized: "Structured"), id: "toolbar.structured",
        symbol: "list.bullet.indent"
    ) { [weak self] in
        self?.presenter.toggleStructuredMode()
    }
    private let message = Deck.caption("")
    private lazy var expand = SmartDiffControls.button(String(localized: "Show all"), id: "toolbar.expand") {
        [weak self] in self?.presenter.toggleAllNoise()
    }
    private lazy var banner: NSView = {
        let pill = ThemedBackgroundView()
        pill.color = Deck.quietFill
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 12
        let content = Deck.hstack([message, expand], spacing: 4)
        Deck.pin(content, in: pill, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
        pill.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return pill
    }()
    init(presenter: SmartDiffPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        let row = Deck.hstack([noise, moves, structured, Deck.spacer()], spacing: 4)
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let stack = Deck.vstack([row, banner], spacing: 0)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        Deck.pin(stack, in: self, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
        smartDiffAccessibility(String(localized: "Diff controls"), "toolbar.view")
        render(presenter.state)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(presenter:)") }

    func render(_ state: SmartDiffState) {
        let options = presenter.options
        SmartDiffControls.select(noise, options.hideNoise)
        SmartDiffControls.select(moves, options.detectMoves)
        banner.isHidden = true
        expand.isHidden = false
        noise.isEnabled = false
        moves.isEnabled = false
        structured.isEnabled = false
        SmartDiffControls.select(structured, false)
        noise.parts = SmartDiffControls.parts(String(localized: "Noise filter"), symbol: "line.3.horizontal.decrease")
        moves.parts = SmartDiffControls.parts(String(localized: "Moves"), symbol: "arrow.left.arrow.right")
        structured.parts = SmartDiffControls.parts(String(localized: "Structured"), symbol: "list.bullet.indent")
        noise.setAccessibilityHelp(nil)
        moves.setAccessibilityHelp(nil)
        guard case .loaded(let snapshot) = state else { return }
        if case .parsed = snapshot.structured { structured.isEnabled = true }
        let raw = !(structured.isEnabled && options.preferStructured)
        SmartDiffControls.select(structured, !raw)
        structured.toolTip =
            raw ? String(localized: "Switch to structured diff") : String(localized: "Switch to raw diff")
        noise.isEnabled = raw
        moves.isEnabled = raw
        addBadge(snapshot.filtered.hiddenNoiseHunkCount, to: noise)
        addBadge(snapshot.moves.matches.count, to: moves)
        noise.setAccessibilityHelp(snapshot.filtered.summaryText)
        let count = snapshot.moves.matches.count
        moves.setAccessibilityHelp(count == 1 ? String(localized: "1 move") : String(localized: "\(count) moves"))
        renderBanner(snapshot, raw: raw)
    }

    private func addBadge(_ count: Int, to button: PartsButton) {
        guard count > 0 else { return }
        let fill = button.background == .selected ? Theme.window : Deck.segmentFill
        button.parts.append(.badge(count.formatted(), fill: fill, color: Theme.text))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render(presenter.state)
    }

    private func renderBanner(_ snapshot: SmartDiffSnapshot, raw: Bool) {
        let showingAll = snapshot.filtered.hiddenNoiseHunkCount == 0
        banner.isHidden = !raw || (showingAll && snapshot.expandedNoiseHunks.isEmpty)
        message.stringValue =
            showingAll ? String(localized: "Formatting and import changes shown") : snapshot.filtered.summaryText
        message.toolTip = message.stringValue
        let action = showingAll ? String(localized: "Hide again") : String(localized: "Show all")
        expand.parts = [.text(action, font: Theme.body, color: Deck.link)]
        expand.setAccessibilityLabel(action)
        expand.toolTip = action
        showStructuredStatus(snapshot)
    }

    private func showStructuredStatus(_ snapshot: SmartDiffSnapshot) {
        guard snapshot.options.preferStructured, banner.isHidden else {
            expand.isHidden = false
            return
        }
        switch snapshot.structured {
        case .fallback(_, let reason): message.stringValue = reason
        case .parsed(_, _, true): message.stringValue = String(localized: "Showing the first structured changes")
        default: return
        }
        message.toolTip = message.stringValue
        banner.isHidden = false
        expand.isHidden = true
    }

    override func draw(_: NSRect) { SmartDiffControls.bar(self, color: Theme.toolbar) }
}
