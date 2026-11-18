import Foundation

/// Reads the signal parts that are due and keeps the others. A failed read keeps the previous value until the next
/// read; it never becomes a guessed state.
struct VercelSignalReader: Sendable {
    enum SignalRead<Value: Sendable>: Sendable {
        case value(Value)
        case empty, failed

        var outcome: VercelSignals.Outcome {
            switch self {
            case .value: .value
            case .empty: .empty
            case .failed: .failed
            }
        }
    }

    /// One part's result and how it changes the signals. A failed read keeps the previous value; `failed` marks
    /// what in it is no longer current.
    struct PartRead: Sendable {
        let part: VercelSignals.Part
        let outcome: VercelSignals.Outcome
        let apply: @Sendable (inout VercelSignals) -> Void

        init<Value: Sendable>(
            _ part: VercelSignals.Part, _ read: SignalRead<Value>,
            failed: @escaping @Sendable (inout VercelSignals) -> Void = { _ in },
            set: @escaping @Sendable (inout VercelSignals, Value?) -> Void
        ) {
            self.part = part
            outcome = read.outcome
            apply = { signals in
                switch read {
                case .value(let value): set(&signals, value)
                case .empty: set(&signals, nil)
                case .failed: failed(&signals)
                }
            }
        }
    }

    let executor: ProviderCommandExecutor
    let cache: VercelPlatformCache
    let clock: @Sendable () -> Date

    /// `live` is the live production deployment (for the error counts); `fingerprint` identifies the listed
    /// deployments, whose change re-reads CI and the rollout.
    func read(
        link: VercelLink, live: String?, fingerprint: String, previous: VercelSignals?, force: Bool
    ) async -> VercelSignals {
        var signals = previous ?? VercelSignals()
        guard let project = link.parts?.project else { return signals }
        let now = clock()
        let keys = Dictionary(
            uniqueKeysWithValues: VercelSignals.Part.allCases.map {
                ($0, Self.key($0, live: live, fingerprint: fingerprint))
            })
        let due = VercelSignals.Part.allCases.filter { part in
            (part != .errors || link.teamID != nil && live != nil)
                && signals.isDue(part, key: keys[part] ?? "", now: now, force: force)
        }
        if live == nil {
            signals.errors = nil
            signals.reads[.errors] = nil
        }
        let context = Context(link: link, project: project, live: live ?? "", force: force, now: now)
        let reads = await withTaskGroup(of: PartRead.self) { group in
            for part in due { group.addTask { await self.read(part, context) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        guard !Task.isCancelled, VercelLinkReader.sourceID(at: link.root) == link.sourceID else {
            return previous ?? VercelSignals()
        }
        for read in reads {
            read.apply(&signals)
            signals.reads[read.part] = VercelSignals.Read(at: now, key: keys[read.part] ?? "", outcome: read.outcome)
        }
        if let errors = signals.errors, errors.deploymentID != live { signals.errors = nil }
        return signals
    }

    private static func key(_ part: VercelSignals.Part, live: String?, fingerprint: String) -> String {
        switch part {
        case .errors: live ?? ""
        case .ci, .rollout: fingerprint
        case .agentRuns, .alerts, .platform: ""
        }
    }

    private struct Context: Sendable {
        let link: VercelLink
        let project: String
        let live: String
        let force: Bool
        let now: Date
    }

    private func read(_ part: VercelSignals.Part, _ context: Context) async -> PartRead {
        let root = context.link.root
        switch part {
        case .errors:
            return PartRead(part, await errors(root: root, deploymentID: context.live)) { $0.errors = $1 }
        case .ci:
            let arguments = ["ci", "list", "--all-branches", "--json", "--limit", "30", "--non-interactive"]
            return PartRead(part, await decodeList(root, arguments, VercelSignalParsers.ciRuns)) { $0.ci = $1 ?? [] }
        case .rollout:
            let path = VercelCommands.path(
                "/v1/projects/\(context.project)/rolling-release", teamID: context.link.teamID)
            let read = await decode(root, VercelCommands.get(path), VercelSignalParsers.rollout)
            return PartRead(part, read, failed: { $0.rollout?.freshness = .stale }, set: { $0.rollout = $1 })
        case .agentRuns:
            let arguments = ["agent-runs", "list", "--json", "--since", "1d", "--limit", "20", "--non-interactive"]
            return PartRead(part, await decode(root, arguments, VercelSignalParsers.agentRuns)) { $0.agentRuns = $1 }
        case .alerts:
            let arguments = ["alerts", "--json", "--since", "24h", "--limit", "20", "--non-interactive"]
            return PartRead(part, await decodeList(root, arguments, VercelSignalParsers.alerts)) {
                $0.alerts = $1 ?? []
            }
        case .platform:
            return PartRead(part, await platform(root: root, force: context.force, now: context.now)) {
                $0.platform = $1
            }
        }
    }

    private func decode<Value: Sendable>(
        _ root: URL, _ arguments: [String], _ parser: @Sendable (Data) throws -> Value?
    ) async -> SignalRead<Value> {
        guard case .success(let data) = await executor.execute(.vercel, arguments, in: root) else { return .failed }
        do {
            return try parser(data).map(SignalRead.value) ?? .empty
        } catch {
            return .failed
        }
    }

    /// A list read: an empty list is an empty read.
    private func decodeList<Element: Sendable>(
        _ root: URL, _ arguments: [String], _ parser: @escaping @Sendable (Data) throws -> [Element]
    ) async -> SignalRead<[Element]> {
        await decode(root, arguments) { data in
            let list = try parser(data)
            return list.isEmpty ? nil : list
        }
    }

    /// Two counting reads of the live deployment's last hour; nothing but the count fields is decoded.
    private func errors(root: URL, deploymentID: String) async -> SignalRead<VercelSignals.Errors> {
        guard VercelIdentifiers.isDeploymentID(deploymentID) else { return .failed }
        let common = ["--deployment", deploymentID, "--since", "1h", "--limit", "100", "--json", "--non-interactive"]
        async let server = count(
            root, ["logs", "requests"] + common + ["--query", "httpStatus >= 500"], "request", deploymentID)
        async let logged = count(
            root, ["logs"] + common + ["--query", "level:error OR level:fatal"], "log", deploymentID)
        let (serverCount, loggedCount) = await (server, logged)
        guard serverCount != nil || loggedCount != nil else { return .failed }
        return .value(
            VercelSignals.Errors(
                deploymentID: deploymentID, serverErrors: serverCount?.count, loggedErrors: loggedCount?.count,
                serverCapped: serverCount?.capped ?? false, loggedCapped: loggedCount?.capped ?? false))
    }

    private func count(
        _ root: URL, _ arguments: [String], _ kind: String, _ deploymentID: String
    ) async
        -> VercelSignalParsers.Count?
    {
        guard case .success(let data) = await executor.execute(.vercel, arguments, in: root) else { return nil }
        return try? VercelSignalParsers.count(data, kind: kind, deploymentID: deploymentID)
    }

    /// Vercel's status is the same for every repository: a recent shared read answers without a command.
    private func platform(root: URL, force: Bool, now: Date) async -> SignalRead<VercelSignals.Platform> {
        let maxAge = VercelSignals.lifetime(.platform, outcome: .value, busy: false)
        if !force, case .hit(let cached) = cache.lookup(maxAge: maxAge, now: now) {
            return cached.map(SignalRead.value) ?? .failed
        }
        let result = await decode(root, ["health", "--json", "--non-interactive"], VercelSignalParsers.platform)
        if case .value(let platform) = result {
            cache.store(platform, now: now)
        } else {
            cache.store(nil, now: now)
        }
        return result
    }
}
