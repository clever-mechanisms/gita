import Foundation

/// A command-line tool a provider adapter runs, with the brand name its diagnostics use.
enum ProviderTool: String, Sendable {
    case gh, vercel, orca, git

    /// The Vercel CLI prefers these routing overrides to `.vercel/project.json`; reads bind to the verified checkout
    /// link, so the CLI never sees them.
    static let vercelRoutingOverrides: Set<String> = [
        "VERCEL_ORG_ID", "VERCEL_PROJECT_ID", "NOW_ORG_ID", "NOW_PROJECT_ID",
    ]

    var executable: String { rawValue }

    var displayName: String {
        switch self {
        case .gh: "GitHub"
        case .vercel: "Vercel"
        case .orca: "Orca"
        case .git: "Git"
        }
    }

    /// The environment this tool runs with.
    var environment: ChildEnvironmentPolicy {
        switch self {
        case .git: .git
        case .vercel: .tool(removing: Self.vercelRoutingOverrides)
        case .gh: .tool
        case .orca: .orca
        }
    }
}
