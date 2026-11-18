import Foundation
import GitaCore

/// The settings the Setup Guide drafts; the app applies only the ones the guide changed.
struct SetupChoices: Equatable, Sendable {
    /// The on/off settings the guide offers, in the order its steps show them.
    static let switchable: [Preference] =
        [.collapsesMergedCommits, .squashMergesAsMerges, .showsHistoryDetails]
        + [.useGitHub, .useVercel, .useOrca, .providerRefresh]
        + [.useAgents] + AgentTool.allCases.map(\.detectionPreference)

    var historyZoomPercent: Int
    /// Every `switchable` setting's drafted value.
    var switches: [Preference: Bool]

    subscript(_ preference: Preference) -> Bool {
        get { switches[preference] ?? false }
        set { switches[preference] = newValue }
    }

    /// One drafted setting that differs from the guide's starting point.
    enum Change: Equatable, Sendable {
        case historyZoomPercent(Int)
        case setting(Preference, Bool)
    }

    /// The edits made since `original`, so finishing never overwrites a setting the guide did not touch.
    func changes(from original: Self) -> [Change] {
        var changes: [Change] = []
        if historyZoomPercent != original.historyZoomPercent {
            changes.append(.historyZoomPercent(HistoryZoom.bounded(historyZoomPercent)))
        }
        for preference in Self.switchable where self[preference] != original[preference] {
            changes.append(.setting(preference, self[preference]))
        }
        return changes
    }
}

extension SetupChoices {
    /// The settings as they are stored now.
    init(defaults: UserDefaults, historyZoomPercent: Int) {
        self.historyZoomPercent = historyZoomPercent
        switches = Dictionary(uniqueKeysWithValues: Self.switchable.map { ($0, $0.bool(defaults)) })
    }

    /// The active repository's settings.
    @MainActor init(model: AppModel) {
        self.init(defaults: model.defaults, historyZoomPercent: model.historyZoomPercent)
        self[.showsHistoryDetails] = model.showsHistoryDetails
    }
}

/// The guide's version: a launch shows it once per version. Version 2 is the redesigned guide, shown once more.
enum SetupGuideState {
    static let version = 2
    static let defaultsKey = "setupGuideVersion"
}
