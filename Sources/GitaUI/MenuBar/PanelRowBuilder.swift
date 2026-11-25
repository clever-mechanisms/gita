import Foundation
import GitaCore

/// Pure: the panel state and the open summaries → the rows of each page.
@MainActor
struct PanelRowBuilder {
    let state: MenuPanelState
    let expanded: Set<String>
    let now: Date

    func rows(_ page: PanelPage) -> [PanelRow] {
        switch page {
        case .inbox: updateRows() + attentionRows() + agentRows() + workspaceRows()
        case .activity: feedRows()
        }
    }

    func updateRows() -> [PanelRow] {
        guard let version = state.pendingUpdateVersion else { return [] }
        let title = String(localized: "Version \(version) is available")
        let subtitle = String(localized: "Software updates")
        let actionTitle = String(localized: "Install Update")
        let chip = PanelChip(title: actionTitle, style: .accent, action: .installUpdate, label: actionTitle)
        return [
            PanelRow(
                id: "update:available", kind: .attention, lead: .symbol("arrow.down.circle.fill", .accentText),
                title: title, subtitle: subtitle, chips: [chip], action: .installUpdate,
                label: "\(title), \(actionTitle)")
        ]
    }

    func name(for url: URL) -> String { state.names[ProviderActivity.key(url)] ?? url.lastPathComponent }

    /// A section's caption, with how many it holds when that says something.
    func header(_ id: String, _ title: String, count: Int = 0) -> PanelRow {
        PanelRow(
            id: "section:" + id, kind: .header, title: title, titleColor: .secondary,
            count: count > 0 ? "\(count)" : nil, label: count > 0 ? "\(title), \(count)" : title)
    }

    /// The folder a session belongs to in the panel: its repository, else its checkout, else where it runs.
    static func home(_ session: AgentSession) -> URL {
        session.repositoryRoot ?? session.checkoutRoot ?? session.workingDirectory
    }
}
