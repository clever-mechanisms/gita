import Foundation
import GitaCore

/// A provider or tool Gita can show, each one switchable in Settings › Integrations or AI Agents (and in the setup
/// guide). Off, it is not read (no CLI call) and nothing of it shows: GitHub's Pull Requests, Workflows and checks;
/// Vercel's Deployments and previews; Orca's task titles and terminals; the coding agents' sessions and marks.
enum Integration: CaseIterable {
    case github, vercel, orca, agents

    var preference: Preference {
        switch self {
        case .github: .useGitHub
        case .vercel: .useVercel
        case .orca: .useOrca
        case .agents: .useAgents
        }
    }

    /// The provider whose reports this integration reads; nil for the coding agents (read by `AgentMonitor`).
    var provider: ProviderKind? {
        switch self {
        case .github: .github
        case .vercel: .vercel
        case .orca: .orca
        case .agents: nil
        }
    }

    init?(_ provider: ProviderKind) {
        guard let integration = Self.allCases.first(where: { $0.provider == provider }) else { return nil }
        self = integration
    }

    func isEnabled(_ defaults: UserDefaults = Preference.store) -> Bool { preference.bool(defaults) }

    static func isEnabled(_ provider: ProviderKind, _ defaults: UserDefaults = Preference.store) -> Bool {
        Self(provider)?.isEnabled(defaults) ?? true
    }

    /// The integration a changed preference switches, if any.
    init?(switchedBy preference: Preference?) {
        guard let integration = Self.allCases.first(where: { $0.preference == preference }) else { return nil }
        self = integration
    }
}
