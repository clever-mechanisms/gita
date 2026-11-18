import Foundation

/// `orca terminal list --worktree path:<checkout> --json`. Orca's terminal host outlives the app, so the process
/// tree cannot name the tab an agent runs in; the terminal list can.
enum OrcaTerminalParser {
    /// The local terminal in `checkout` whose tab title is the agent's task title, else the one that printed most
    /// recently, else the only one.
    static func handle(_ data: Data, checkout: String, title: String?) throws -> String? {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.ok, let result = envelope.result else { throw ProviderResponseError.shape }
        let path = OrcaAgentParser.normalizedPath(checkout)
        let here = result.terminals.filter {
            ($0.executionHostId ?? "local") == "local" && $0.connected && $0.handle.hasPrefix("term_")
                && $0.worktreePath.map(OrcaAgentParser.normalizedPath) == path
        }
        if let title = trimmed(title), let named = here.first(where: { trimmed($0.title) == title }) {
            return named.handle
        }
        let printed = here.compactMap { terminal in terminal.lastOutputAt.map { (terminal.handle, $0) } }
        if let recent = printed.max(by: { $0.1 < $1.1 }) { return recent.0 }
        return here.count == 1 ? here[0].handle : nil
    }

    private static func trimmed(_ text: String?) -> String? {
        ProviderValidation.nonempty(text?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private struct Envelope: Decodable {
        struct Result: Decodable { var terminals: [Terminal] }

        @DecodedDefault<DefaultFalse> var ok: Bool
        var result: Result?
    }

    private struct Terminal: Decodable {
        var handle: String
        var worktreePath: String?
        var title: String?
        var lastOutputAt: Double?
        @DecodedDefault<DefaultTrue> var connected: Bool
        var executionHostId: String?
    }
}
