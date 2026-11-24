import Foundation

/// The Orca adapter: agent sessions Orca reports for this repository's local worktrees, and bringing an agent's
/// terminal tab to the front. It never starts the Orca runtime.
struct OrcaProvider: Sendable {
    let executor: ProviderCommandExecutor

    func report(root: URL) async -> ProviderReport {
        async let worktrees = localWorktrees(root: root)
        async let process = workspaces(in: root)
        let (knownWorktrees, result) = await (worktrees, process)
        return Self.report(result, worktrees: knownWorktrees)
    }

    /// The sessions Orca reports in these checkouts, from one `orca worktree ps` and no Git call. Orca lists every
    /// local workspace whatever folder it runs in, and the agent monitor already knows each session's checkout, so
    /// asking once per repository (and listing its worktrees with Git) would only repeat the same answer: each Orca
    /// call starts an Electron helper costing ~0.15 s of CPU.
    func report(checkouts: [URL]) async -> ProviderReport {
        guard let first = checkouts.first else { return Self.report(.success(Data()), worktrees: []) }
        let worktrees = checkouts.map { GitWorktree(path: $0.path, branch: nil, head: "") }
        return Self.report(await workspaces(in: first), worktrees: worktrees)
    }

    private func workspaces(in directory: URL) async -> Result<Data, ProviderFailure> {
        await execute(["worktree", "ps", "--json", "--agent-wait", "--limit", "100"], in: directory)
    }

    private static func report(_ result: Result<Data, ProviderFailure>, worktrees: [GitWorktree]) -> ProviderReport {
        if Task.isCancelled { return ProviderReport(.orca, failure: .cancelled) }
        switch result {
        case .failure(let failure): return ProviderReport(.orca, failure: failure)
        case .success(let data):
            guard !worktrees.isEmpty else {
                return ProviderReport(
                    .orca, status: .unavailable,
                    diagnostic: String(localized: "Could not resolve this repository’s worktrees."))
            }
            guard let page = try? OrcaAgentParser.page(data, worktrees: worktrees) else {
                return ProviderReport(.orca, failure: .unsupportedResponse(.orca))
            }
            return ProviderReport(
                .orca, items: page.items, status: page.truncated ? .partial : .connected, diagnostic: diagnostic(page))
        }
    }

    static func diagnostic(_ page: OrcaAgentParser.Page) -> String {
        var diagnostics = [
            page.truncated
                ? String(localized: "Orca returned a limited workspace page; some sessions may be missing.")
                : String(localized: "Current local Orca sessions reported for this repository.")
        ]
        if page.remoteHostsOmitted { diagnostics.append(String(localized: "Paired hosts were not queried.")) }
        if page.items.contains(where: { $0.agent?.role == .subagent && $0.worktreePath == nil }) {
            diagnostics.append(
                String(localized: "Delegated agents without a reported worktree have no branch or commit association."))
        }
        return diagnostics.joined(separator: " ")
    }

    /// Brings the Orca terminal tab an agent runs in to the front (`orca terminal switch`). False when Orca is
    /// unavailable or no terminal in `checkout` matches; the caller still activates Orca.
    func switchTerminal(checkout: URL, title: String?) async -> Bool {
        guard
            case .success(let data) = await execute(
                ["terminal", "list", "--worktree", "path:" + checkout.path, "--json"], in: checkout),
            let handle = try? OrcaTerminalParser.handle(data, checkout: checkout.path, title: title)
        else { return false }
        if case .success = await execute(["terminal", "switch", "--terminal", handle, "--json"], in: checkout) {
            return true
        }
        return false
    }

    private func localWorktrees(root: URL) async -> [GitWorktree] {
        guard
            case .success(let data) = await executor.execute(.git, ["worktree", "list", "--porcelain", "-z"], in: root)
        else { return [] }
        return GitParsers.worktrees(data).filter { !$0.isBare }
    }

    /// Orca exits 0 with `{"ok": false, "error": …}` when it is not running or refuses a request.
    private func execute(_ arguments: [String], in root: URL) async -> Result<Data, ProviderFailure> {
        await executor.execute(.orca, arguments, in: root).flatMap { data in
            guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), envelope.ok == false else {
                return .success(data)
            }
            let reason = (envelope.error?.code ?? "") + " " + (envelope.error?.message ?? "")
            return .failure(ProviderFailureClassifier.classify(reason, tool: .orca, exitCode: nil))
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            var code: String?
            var message: String?
        }

        /// A missing `ok` means success.
        var ok: Bool
        var error: Detail?

        private enum CodingKeys: String, CodingKey { case ok, error }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decode(DecodedDefault<DefaultTrue>.self, forKey: .ok).wrappedValue
            error = try container.decodeIfPresent(Detail.self, forKey: .error)
        }
    }
}
