import Foundation
import GitaCore

/// Activity: what happened across repositories, newest first. A row opens its page, else brings its agent forward,
/// else shows its repository.
extension PanelRowBuilder {
    func feedRows() -> [PanelRow] {
        guard !state.feed.isEmpty else {
            return [PanelRow(id: "empty", kind: .message, title: String(localized: "Nothing new"))]
        }
        return state.feed.map(feedRow)
    }

    private func feedRow(_ event: FeedEvent) -> PanelRow {
        let (symbol, color) = event.kind.panelSymbol
        var row = PanelRow(
            id: "feed:" + event.id, kind: .item, lead: .symbol(symbol, color), title: event.title,
            suffix: event.repositoryName, subtitle: event.detail.isEmpty ? nil : event.detail,
            time: PanelTime.duration(since: event.date, now: now, units: 1), action: Self.action(event))
        if let url = event.url {
            row.hoverChip = PanelChip(
                title: "", symbol: "doc.on.doc", action: .copy(url.absoluteString),
                label: String(localized: "Copy URL"))
        }
        row.label = [event.title, event.repositoryName, event.detail, row.time].compactMap { $0 }.filter {
            !$0.isEmpty
        }.joined(separator: ", ")
        return row
    }

    static func action(_ event: FeedEvent) -> PanelAction {
        if let url = event.url { return .openURL(url) }
        if let session = event.sessionID { return .reveal(session) }
        return .showRepository(event.repository)
    }
}
