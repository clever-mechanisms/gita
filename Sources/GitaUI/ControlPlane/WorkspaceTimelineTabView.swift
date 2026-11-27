import AppKit
import GitaCore

@MainActor
final class WorkspaceTimelineTabView: NSView {
    private let presenter: WorkspaceCommandCenterPresenter
    private let strip = NSSegmentedControl(
        labels: [
            String(localized: "All"), String(localized: "Commits"),
            String(localized: "PRs"), String(localized: "Deploys"),
        ], trackingMode: .selectOne, target: nil, action: nil)
    private let rows = WorkspaceRows(
        id: "workspace.timeline", title: String(localized: "Workspace timeline"), height: 64)

    init(_ presenter: WorkspaceCommandCenterPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        strip.target = self
        strip.action = #selector(filter)
        strip.font = Theme.body
        AgentControlUI.applySegmentSymbols(
            strip,
            symbols: [
                "tray.full", "point.topleft.down.to.point.bottomright.curvepath", "arrow.triangle.pull", "shippingbox",
            ])
        ControlPlaneViews.identify(strip, "workspace.timeline.filter", String(localized: "Event kind"))
        let stack = Deck.vstack([strip, rows], spacing: 12)
        Deck.pin(stack, in: self)
        rows.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder _: NSCoder) { nil }
    @objc private func filter() { presenter.setFilter(.init(rawValue: strip.selectedSegment) ?? .all) }

    func render() {
        strip.selectedSegment = presenter.filter.rawValue
        switch presenter.timeline {
        case .empty:
            rows.message(String(localized: "No workspace events yet."), symbol: "clock.arrow.circlepath")
        case .idle, .loading: rows.message(String(localized: "Reading workspace history…"), loading: true)
        case .failed(let message):
            rows.message(message, symbol: "exclamationmark.triangle.fill") { [weak presenter] in presenter?.refresh() }
        case .loaded:
            let values = presenter.filteredEvents
            if values.isEmpty {
                rows.message(
                    String(localized: "No events match this filter."), symbol: "line.3.horizontal.decrease.circle")
            } else {
                rows.show(count: values.count) { Self.row(values[$0]) }
            }
        }
    }

    private static func stateTitle(_ state: SignalState) -> String {
        switch state {
        case .success: String(localized: "Passed")
        case .failure: String(localized: "Failed")
        case .pending: String(localized: "Pending")
        case .running: String(localized: "Running")
        case .cancelled: String(localized: "Cancelled")
        case .neutral: String(localized: "Neutral")
        }
    }

    private static func row(_ event: WorkspaceTimelineEvent) -> NSView {
        let symbol: String
        let label: String
        switch event.kind {
        case .commit:
            (symbol, label) = ("point.topleft.down.to.point.bottomright.curvepath", String(localized: "Commit"))
        case .pullRequest(let number, _, _):
            (symbol, label) = ("arrow.triangle.pull", String(localized: "PR #\(number)"))
        case .deployment(let environment, _, _): (symbol, label) = ("shippingbox", environment)
        }
        let stateColor = Theme.color(for: event.state)
        let state = ControlPlaneBadge(
            stateTitle(event.state), symbol: Style.stateSymbol(event.state),
            fill: stateColor.withAlphaComponent(0.12), text: stateColor,
            border: stateColor.withAlphaComponent(0.32))
        let info = Deck.hstack([
            ControlPlaneViews.repoLabel(event.repository), Deck.caption(label), state,
            Deck.label(
                [event.branch, event.commitSHA.map { String($0.prefix(8)) }].compactMap { $0 }.joined(separator: " · "),
                font: Theme.mono, color: Theme.secondaryText),
        ])
        let title = Deck.label(event.title, font: Theme.bodyEmphasis)
        title.toolTip = event.title
        let content = Deck.vstack([title, info])
        content.toolTip = event.subtitle
        let badge = StorageStyle.iconBadge(symbol, tint: stateColor, boxSize: 28, symbolSize: 13, cornerRadius: 7)
        return Deck.hstack(
            [
                badge, content, Deck.spacer(),
                Deck.caption(DeckFormat.relative(event.timestamp)),
            ], spacing: 12)
    }
}
