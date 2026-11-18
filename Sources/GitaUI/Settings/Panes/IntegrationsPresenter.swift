import AppKit
import GitaCore

/// What the Integrations pane shows for the active repository's provider reports, the agents and their hooks.
@MainActor
enum IntegrationsPresenter {
    /// A repository row: the repository's name, the provider's status and its colour.
    struct RepositoryRow: Equatable {
        var title: String
        var value: String
        var status: ProviderStatus
        var tooltip: String?
    }

    /// The row for `provider` in the repository, nil (hidden) when there is no repository or no report.
    static func repositoryRow(
        _ provider: ProviderKind, repository: String?, reports: [ProviderReport]
    ) -> RepositoryRow? {
        guard let repository, let report = reports.first(where: { $0.provider == provider }) else { return nil }
        return RepositoryRow(
            title: repository, value: value(of: report), status: report.status, tooltip: report.diagnostic)
    }
    /// A connected Vercel project reads "scope / project"; everything else its status.
    private static func value(of report: ProviderReport) -> String {
        guard report.provider == .vercel, report.status == .connected,
            case .deployment(_, let project, let scope)? = report.items.lazy.compactMap(\.target).first
        else { return report.localizedStatus }
        return [scope, project].compactMap { $0 }.joined(separator: " / ")
    }

    static func statusColor(_ status: ProviderStatus) -> NSColor {
        switch status {
        case .connected: Theme.success
        case .signInRequired, .accessDenied, .updateCLI, .projectChanged: Theme.needsInput
        case .noRemote, .notGitHub, .notLinked, .notInstalled, .cancelled: Theme.idle
        case .partial, .unavailable, .offline, .timedOut, .responseTooLarge, .repositoryChanged: Theme.failure
        }
    }
    static func accountColor(_ status: CLIAccountProbe.Status) -> NSColor {
        switch status {
        case .connected: Theme.success
        case .attention: Theme.needsInput
        case .failed: Theme.failure
        case .idle: Theme.idle
        }
    }

    /// An account row: its value, the dot's colour and the tooltip.
    struct AccountRow: Equatable {
        var value: String
        var color: NSColor?
        var tooltip: String?
    }
    /// "Checking…" until the first read answers. A recheck keeps the last value on screen with its dot in the
    /// running colour and "Checking…" as its tooltip, so stale values never pass for fresh ones.
    static func accountRow(_ account: CLIAccountProbe.Account?, checking: Bool) -> AccountRow {
        let checkingText = String(localized: "Checking…")
        guard let account else { return AccountRow(value: checkingText, color: nil) }
        if checking { return AccountRow(value: account.value, color: Theme.running, tooltip: checkingText) }
        return AccountRow(value: account.value, color: accountColor(account.status), tooltip: account.tooltip)
    }

    /// "1 needs input · 2 working" for one tool's sessions, most urgent first.
    static func agentNote(_ sessions: [AgentSession]) -> String {
        let summary = AgentSummary(sessions)
        var parts: [String] = []
        if summary.needsInput > 0 { parts.append(String(localized: "\(summary.needsInput) needs input")) }
        if summary.working > 0 { parts.append(String(localized: "\(summary.working) working")) }
        if summary.done > 0 { parts.append(String(localized: "\(summary.done) done")) }
        if summary.idle > 0 { parts.append(String(localized: "\(summary.idle) idle")) }
        return parts.joined(separator: " · ")
    }

    /// A hook row: its status, colour and which buttons show.
    struct HookRow: Equatable {
        var status: String
        var installTitle: String
        var showsInstall: Bool
        var showsRemove: Bool
    }
    /// `throughOrca`: Orca reports the agents' states, so hooks not yet installed are not offered.
    static func hookRow(_ status: AgentMonitor.HookStatus, throughOrca: Bool = false) -> HookRow {
        let install = String(localized: "Install Hooks…")
        if throughOrca && status == .notInstalled {
            return HookRow(
                status: AgentConnectionState.throughOrcaStatus, installTitle: install, showsInstall: false,
                showsRemove: false)
        }
        switch status {
        case .installed:
            return HookRow(
                status: String(localized: "Installed"), installTitle: install, showsInstall: false, showsRemove: true)
        case .needsUpdate:
            return HookRow(
                status: String(localized: "Update available"), installTitle: String(localized: "Update Hooks…"),
                showsInstall: true, showsRemove: true)
        case .notInstalled:
            return HookRow(
                status: String(localized: "Not installed"), installTitle: install, showsInstall: true,
                showsRemove: false)
        case .unavailable(let reason):
            return HookRow(status: reason, installTitle: install, showsInstall: false, showsRemove: false)
        }
    }
    static func hookColor(_ status: AgentMonitor.HookStatus, throughOrca: Bool = false) -> NSColor {
        if throughOrca && status == .notInstalled { return Theme.success }
        return switch status {
        case .installed: Theme.success
        case .needsUpdate: Theme.needsInput
        case .notInstalled, .unavailable: Theme.idle
        }
    }
    /// The configuration file the hooks go into, as the install confirmation names it.
    static func hookFile(_ tool: AgentTool) -> String {
        tool == .codex ? "~/.codex/config.toml" : "~/.claude/settings.json"
    }
}
