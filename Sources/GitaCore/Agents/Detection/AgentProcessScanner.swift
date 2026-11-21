import Darwin
import Foundation

/// Samples every agent process on this Mac with libproc. One actor-owned cache keeps the per-process classification
/// (path read once per process instance) and per-process CPU so samples report monotonic CPU deltas.
public actor AgentProcessScanner {
    /// Descendants older than this are long-lived helpers (MCP servers, dev servers) and do not make a session
    /// "working".
    public static let descendantWindow: TimeInterval = 15 * 60

    /// What a pid was when last classified. `exec` keeps the pid and its start time but changes the command name;
    /// a reused pid has a new start time. Only agents have their start time read (one more syscall each), so a
    /// non-agent is matched by the short info alone: a new parent or name sends it back through the classifier.
    enum Known: Sendable, Equatable {
        case notAgent(parent: Int32, name: String)
        case agent(name: String, start: UInt64, identity: AgentProcessIdentity)

        /// Whether this verdict is still about the process `row` shows; `start` is read only for an agent.
        func describes(_ row: AgentScanPass.Row, start: () -> UInt64?) -> Bool {
            switch self {
            case .notAgent(let parent, let name): parent == row.parent && name == row.name
            case .agent(let name, let since, _): name == row.name && start() == since
            }
        }

        var identity: AgentProcessIdentity? {
            if case .agent(_, _, let identity) = self { identity } else { nil }
        }
    }
    /// What decides which descendants count toward a session's CPU.
    private struct DescendantRule {
        var sessions: Set<Int32>
        var links: AgentScanPass.Links
        var now: UInt64

        func counts(_ pid: Int32, _ entry: AgentProcessTable.Entry) -> Bool {
            links.mergedInto[pid] != nil || entry.start + UInt64(descendantWindow * microsPerSecond) >= now
        }
    }
    private static let microsPerSecond = 1_000_000.0

    private var known: [Int32: Known] = [:]
    private var lastCPU: [Int32: AgentCPUMeter.Mark] = [:]
    private var accumulated: [Int32: (start: UInt64, seconds: Double)] = [:]
    private var lastScan: UInt64 = 0

    public init() {}

    public func scan(now: Date = Date()) -> [AgentProcessSample] {
        // The whole table uses the short info; start time and terminal device are read only for agents and their
        // descendants. A cached classification is dropped as soon as its pid disappears from a scan and re-checked
        // every scan (`Known`), so a reused pid is never mistaken for the agent that had it, and a process that
        // `exec`s into an agent is found. A non-agent pid reused by a process with the same parent and name between
        // two scans keeps its verdict until either changes; macOS hands out pids in increasing order, so this is rare.
        var pass = AgentScanPass(uid: getuid(), excluding: getpid())
        known = known.filter { pass.table[$0.key] != nil }
        let agents = classifyAgents(&pass)
        let directories = Dictionary(
            uniqueKeysWithValues: agents.keys.compactMap { pid in
                AgentProcessTable.workingDirectory(pid).map { (pid, $0) }
            })
        let links = pass.links(agents, directories: directories)
        let sessions = Set(agents.keys.filter { links.mergedInto[$0] == nil && directories[$0] != nil })
        let nowMicros = UInt64(max(0, now.timeIntervalSince1970) * Self.microsPerSecond)
        var meter = AgentCPUMeter(previous: lastCPU, previousScan: lastScan)
        let rule = DescendantRule(sessions: sessions, links: links, now: nowMicros)
        var samples: [AgentProcessSample] = []
        for pid in sessions {
            guard let entry = pass.fullEntry(pid), let identity = agents[pid], let directory = directories[pid] else {
                continue
            }
            let used = sessionCPU(pid, entry, pass: &pass, meter: &meter, rule: rule)
            let total = (accumulated[pid].flatMap { $0.start == entry.start ? $0.seconds : nil } ?? 0) + used
            accumulated[pid] = (entry.start, total)
            samples.append(
                AgentProcessSample(
                    tool: identity.tool, pid: pid, parentAgentPID: links.parentAgent[pid], workingDirectory: directory,
                    startedAt: Date(timeIntervalSince1970: Double(entry.start) / Self.microsPerSecond),
                    cpuSeconds: total,
                    isService: identity.isService || !entry.hasTerminal))
        }
        lastCPU = meter.seen
        accumulated = accumulated.filter { sessions.contains($0.key) }
        lastScan = nowMicros
        return samples.sorted { $0.pid < $1.pid }
    }

    /// Every agent in the table, reusing the cached classification while the pid still names the same process.
    private func classifyAgents(_ pass: inout AgentScanPass) -> [Int32: AgentProcessIdentity] {
        var agents: [Int32: AgentProcessIdentity] = [:]
        for (pid, row) in pass.table {
            if let cached = known[pid], cached.describes(row, start: { pass.fullEntry(pid)?.start }) {
                if let identity = cached.identity { agents[pid] = identity }
                continue
            }
            let identity = AgentProcessTable.executablePath(pid).flatMap { path in
                let reads = AgentProcessClassifier.readsArguments(path: path)
                let arguments = reads ? AgentProcessTable.arguments(pid) : []
                return AgentProcessClassifier.classify(path: path, arguments: arguments)
            }
            known[pid] =
                identity.map { .agent(name: row.name, start: pass.fullEntry(pid)?.start ?? 0, identity: $0) }
                ?? .notAgent(parent: row.parent, name: row.name)
            if let identity { agents[pid] = identity }
        }
        return agents
    }

    /// CPU the session used since the last scan: its own, its wrappers' and its recently started descendants'.
    private func sessionCPU(
        _ pid: Int32, _ entry: AgentProcessTable.Entry, pass: inout AgentScanPass, meter: inout AgentCPUMeter,
        rule: DescendantRule
    ) -> Double {
        var used = meter.seconds(pid, entry)
        for child in pass.descendants(of: pid, excluding: rule.sessions) where rule.counts(child.pid, child.entry) {
            used += meter.seconds(child.pid, child.entry)
        }
        return used
    }
}
