import Foundation

/// Read-only Vercel CLI invocations shared by the readers.
enum VercelCommands {
    /// `vercel api <endpoint>` as a plain GET without prompts.
    static func get(_ endpoint: String, scope: String? = nil) -> [String] {
        ["api", endpoint, "--method", "GET", "--raw", "--non-interactive"] + VercelIdentifiers.scopeArguments(scope)
    }

    /// An API path with its query, plus `teamId` for a team project.
    static func path(_ base: String, _ query: [String] = [], teamID: String?) -> String {
        let all = query + [teamID.map { "teamId=" + $0 }].compactMap { $0 }
        return all.isEmpty ? base : base + "?" + all.joined(separator: "&")
    }
}
