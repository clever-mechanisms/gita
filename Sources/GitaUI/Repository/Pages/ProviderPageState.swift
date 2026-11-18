import Foundation
import GitaCore

/// The Pull Requests, Workflows and Deployments pages: which signals they list and what their header says.
@MainActor
struct ProviderPageState {
    static func isConnected(_ report: ProviderReport?) -> Bool { report?.status == .connected }

    /// The sections shown as provider pages.
    static func isProviderPage(_ section: Section) -> Bool {
        section == .pullRequests || section == .workflows || section == .deployments
    }

    /// The page's integration is on (GitHub for Pull Requests and Workflows, Vercel for Deployments).
    static func isShown(_ section: Section, _ defaults: UserDefaults = Preference.store) -> Bool {
        (section == .deployments ? Integration.vercel : .github).isEnabled(defaults)
    }

    var section: Section
    var items: [ProviderItem]
    var emptyMessage: String
    var status: String
    var statusToolTip: String?
    /// The GitHub pages' account picker; nil on Deployments or when `gh` has one account.
    var accounts: GitHubAccountPicker?

    init(
        section: Section, signals: [ProviderItem], reports: [ProviderReport], accounts: GitHubAccountPicker? = nil
    ) {
        self.section = section
        self.accounts = section == .deployments ? nil : accounts
        items = signals.filter { Self.lists($0, on: section) }
        let report = reports.first { $0.provider == (section == .deployments ? .vercel : .github) }
        let connected = Self.isConnected(report)
        let empty =
            switch section {
            case .deployments: String(localized: "No deployments")
            case .workflows: String(localized: "No workflow runs")
            default: String(localized: "No pull requests")
            }
        emptyMessage = connected ? empty : report?.localizedStatus ?? String(localized: "Not checked")
        var status = connected || items.isEmpty ? "" : report?.localizedStatus ?? ""
        if let date = report?.checkedAt {
            status += (status.isEmpty ? "" : " · ") + String(localized: "Checked \(DeckFormat.relative(date))")
        }
        self.status = status
        statusToolTip = report?.diagnostic
    }

    /// Whether the page lists `item`. The sidebar counts with the same rule, so a count never points at an empty
    /// page. Workflows lists every workflow run: GitHub Actions and Vercel CI jobs alike.
    nonisolated static func lists(_ item: ProviderItem, on section: Section) -> Bool {
        switch section {
        case .deployments: item.provider == .vercel && item.kind == .deployment
        case .pullRequests: item.provider == .github && item.kind == .pullRequest
        case .workflows: item.kind == .workflowRun
        default: false
        }
    }
}
