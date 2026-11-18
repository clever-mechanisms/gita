import Foundation

/// Raw stderr can contain private paths, request URLs or authentication data. It is classified in memory into a
/// status and a fixed diagnostic; the first matching rule wins.
enum ProviderFailureClassifier {
    static func classify(_ raw: String, tool: ProviderTool, exitCode: Int32?) -> ProviderFailure {
        let evidence = Evidence(raw, tool: tool)
        if let rule = rules.first(where: { $0.matches(evidence) }) {
            return ProviderFailure(status: rule.status, diagnostic: rule.message(tool.displayName))
        }
        guard let exitCode else { return .incomplete(tool) }
        return ProviderFailure(
            status: .unavailable,
            diagnostic: String(localized: "\(tool.displayName) CLI exited with status \(exitCode)."))
    }

    /// Lowercased error text, its words and the tool that printed it.
    struct Evidence {
        let text: String
        let words: Set<Substring>
        let tool: ProviderTool

        init(_ raw: String, tool: ProviderTool) {
            text = raw.lowercased()
            words = Set(text.split(whereSeparator: { $0.isWhitespace || Self.wordSeparators.contains($0) }))
            self.tool = tool
        }

        /// A status code or keyword counts only as a word, never inside an id, path or URL.
        private static let wordSeparators: Set<Character> = [":", "(", ")", "[", "]", ",", ";", "=", "\"", "'"]

        func contains(_ phrase: String) -> Bool { text.contains(phrase) }
        func containsAny(_ phrases: [String]) -> Bool { phrases.contains(where: text.contains) }
        func hasWord(_ words: [Substring]) -> Bool { words.contains(where: self.words.contains) }
    }

    struct Rule: Sendable {
        let status: ProviderStatus
        let matches: @Sendable (Evidence) -> Bool
        let message: @Sendable (String) -> String
    }

    static let rules: [Rule] = [
        Rule(
            status: .notInstalled,
            matches: {
                $0.contains("not found") && $0.containsAny(["executable", "command"]) || $0.contains("no such file")
            },
            message: { String(localized: "Install the \($0) CLI to connect this provider.") }),
        Rule(
            status: .offline,
            matches: {
                $0.containsAny(["not running", "not_running", "connection refused"])
                    || $0.contains("enoent") && $0.tool == .orca
            },
            message: { String(localized: "\($0) is not running or cannot be reached.") }),
        Rule(
            status: .signInRequired,
            matches: {
                // Never a bare "login": JSON field names and GraphQL messages contain it on every response.
                $0.containsAny([
                    "auth login", "vercel login", "not logged", "log in", "logged in", "unauthorized",
                    "not authenticated", "authentication", "no existing credentials",
                ]) || $0.hasWord(["401"])
            },
            message: { String(localized: "Sign in using the \($0) CLI in Terminal, then refresh.") }),
        Rule(
            status: .accessDenied,
            matches: { $0.contains("forbidden") || $0.hasWord(["403", "permission", "permissions"]) },
            message: { String(localized: "The current \($0) CLI account cannot read this project.") }),
        Rule(
            status: .timedOut, matches: { $0.containsAny(["timed out", "timeout"]) },
            message: { String(localized: "\($0) did not respond within 20 seconds.") }),
        Rule(
            status: .offline,
            matches: { $0.containsAny(["network", "resolve host", "could not connect", "connection", "offline"]) },
            message: { String(localized: "\($0) could not reach its service.") }),
        Rule(
            status: .responseTooLarge, matches: { $0.contains("output") && $0.containsAny(["limit", "large"]) },
            message: { String(localized: "\($0) exceeded the response limit.") }),
        Rule(
            status: .updateCLI, matches: { $0.containsAny(["unknown option", "unknown flag", "unknown command"]) },
            message: { String(localized: "Update the \($0) CLI to use this integration.") }),
    ]
}
