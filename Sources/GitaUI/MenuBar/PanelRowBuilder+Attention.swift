import Foundation
import GitaCore

/// Needs you: one card per thing that waits for the user, newest first, each with the one action that answers it.
extension PanelRowBuilder {
    func attentionRows() -> [PanelRow] {
        guard !state.attention.isEmpty else {
            let title = String(localized: "Nothing needs you")
            let calm = PanelRow.Lead.symbol("checkmark.circle", .tertiary)
            return [PanelRow(id: "calm", kind: .message, lead: calm, title: title, label: title)]
        }
        return state.attention.map(attentionRow)
    }

    private func attentionRow(_ item: PanelAttention.Item) -> PanelRow {
        let look = Self.look(item)
        var row = PanelRow(
            id: "attention:" + item.id, kind: .attention, lead: .symbol(look.symbol, look.color), title: look.title,
            subtitle: item.detail, time: item.date.map { PanelTime.duration(since: $0, now: now, units: 1) },
            chips: [look.chip], action: look.chip.action)
        row.label = [look.title, item.detail, row.time].compactMap { $0 }.filter { !$0.isEmpty }.joined(
            separator: ", ")
        return row
    }

    /// How a kind of item reads: its title, its symbol in the disc, and its chip.
    private struct Look {
        var title: String
        var symbol: String
        var color: PanelColor
        var chip: PanelChip
    }

    private static func look(_ item: PanelAttention.Item) -> Look {
        // Its page when it has one, else the repository in Gitā.
        let page = item.url.map(PanelAction.openURL) ?? .showRepository(item.repository)
        switch item.kind {
        case .agentWaiting(let tool, let session):
            return Look(
                title: String(localized: "\(tool.displayName) is waiting"), symbol: "bubble.left.fill",
                color: .needsInputText,
                chip: PanelChip(
                    title: String(localized: "Terminal"), style: .attention, action: .reveal(session),
                    label: String(localized: "Bring \(tool.displayName) forward")))
        case .reviewRequested:
            return Look(
                title: String(localized: "Review requested"), symbol: "eye", color: .needsInputText,
                chip: PanelChip(
                    title: String(localized: "Review"), action: page, label: String(localized: "Open Pull Request")))
        case .checksFailed:
            return Look(
                title: String(localized: "Checks failed"), symbol: "xmark", color: .failure,
                chip: PanelChip(
                    title: String(localized: "Open ↗"), action: page, label: String(localized: "Open the failing run")))
        case .conflicts:
            return Look(
                title: String(localized: "Conflicts"), symbol: "exclamationmark.triangle.fill", color: .failure,
                chip: PanelChip(
                    title: String(localized: "Show"), action: .showRepository(item.repository),
                    label: String(localized: "Show in Gitā")))
        }
    }
}
