import Foundation
import GitaCore

/// What a click on a panel row, chip, pill or footer button asks for.
enum PanelAction: Hashable {
    case openURL(URL)
    case copy(String)
    case toggle(String)
    case showRepository(URL)
    /// Opens a repository's tab and switches to the provider's page (Pull Requests or Deployments).
    case showProviderPage(URL, ProviderKind)
    /// A repository's tab in the window of the workspace it is a tab of.
    case showTab(URL, workspace: String)
    case push(URL)
    /// An agent session, by id.
    case reveal(String)
    case openRepository
    /// A workspace, by id: its window comes forward, or it opens.
    case openWorkspace(String)
    case newWorkspace
    /// The list turns into what happened lately.
    case showActivity

    /// The web address the action opens, for ⌘C.
    var link: String? {
        if case .openURL(let url) = self { return url.absoluteString }
        return nil
    }
}

/// A compact one-click action in a row or in the footer.
struct PanelChip: Hashable {
    /// Filled accent or attention, a quiet surface, or text alone: in the accent colour (`link`) or secondary
    /// (`subtle`).
    enum Style: Hashable { case accent, attention, quiet, link, subtle }
    var title: String
    var symbol: String?
    var style: Style = .quiet
    var action: PanelAction
    /// VoiceOver and tooltip; icon-only chips have no title.
    var label: String
}
