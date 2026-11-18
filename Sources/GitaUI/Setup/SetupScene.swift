import Foundation
import GitaCore

/// One animated picture in the Setup Guide. The Welcome step plays one beside each thing Gitā does; the History step
/// one under each option; Integrations, Agents and Ready one across the page.
enum SetupScene: String, CaseIterable {
    /// The whole history: dense, then searched, then zoomed in.
    case history
    /// A few commits with their pull request, checks and preview chips.
    case pullRequests
    /// Agent sessions next to their branch, changing state.
    case agents
    /// The menu bar icon, its panel, then a notification.
    case menuBar
    /// The history with the commit details under it, and without.
    case details
    /// The history at the drafted zoom.
    case zoom
    /// A merge with its commits, then folded into its row.
    case collapse
    /// A squash commit with its branch drawn joining it, and without.
    case squash
    /// A larger history with a Status column, as in the window.
    case status

    /// How many steps the scene cycles through.
    var steps: Int {
        switch self {
        case .history, .pullRequests, .agents, .menuBar, .status: 3
        case .details, .collapse, .squash: 2
        case .zoom: 1
        }
    }

    /// The setting a scene plays off and on, starting on the drafted value.
    var preference: Preference? {
        switch self {
        case .details: .showsHistoryDetails
        case .collapse: .collapsesMergedCommits
        case .squash: .squashMergesAsMerges
        default: nil
        }
    }

    /// The height of the scene when it spans the page.
    var pageHeight: CGFloat {
        switch self {
        case .status: 252
        case .menuBar: 214
        default: 172
        }
    }
}

extension SetupGuideCard {
    /// The scene across the top of the page, when the step has one.
    var pageScene: SetupScene? {
        switch self {
        case .integrations: .status
        case .agents: .agents
        case .ready: .menuBar
        case .welcome, .history, .tools: nil
        }
    }
}
