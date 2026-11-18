import Foundation
import GitaCore

/// What the agents pane shows, one choice for every tab: switching checkouts keeps the state filter, and the order
/// of the repositories after the open one (Status by default, or Name) is remembered across launches.
@MainActor
final class AgentsPaneChoices {
    static let shared = AgentsPaneChoices(defaults: Preference.store)

    var stateFilter: AgentsPaneView.StateFilter = .all
    private(set) var order: RepositoryListOrder
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        order =
            RepositoryListOrder(rawValue: Preference.agentsPaneOrder.string(defaults)).flatMap {
                $0 == .recent ? nil : $0
            } ?? .status
    }

    /// Every tab's pane re-sorts on the preference's change notification.
    func setOrder(_ order: RepositoryListOrder) {
        self.order = order
        Preference.agentsPaneOrder.set(order.rawValue, defaults)
    }
}
