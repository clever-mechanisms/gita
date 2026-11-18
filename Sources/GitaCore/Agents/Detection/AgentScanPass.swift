import Darwin
import Foundation

/// One scan's view of the process table: the cheap short rows for every process, full entries read lazily (only for
/// agents and their descendants) and cached for the rest of the pass.
struct AgentScanPass {
    typealias Row = (parent: Int32, hasTerminal: Bool, name: String)

    /// How an agent below another agent of the same tool relates to it.
    struct Links {
        /// Wrapper processes (same folder and terminal, no shell between) and the session they belong to.
        var mergedInto: [Int32: Int32] = [:]
        /// Delegated runs (subagents) and the session they came from.
        var parentAgent: [Int32: Int32] = [:]
    }

    /// Bounds every walk up or down the tree, so a corrupt or cyclic table cannot stall a scan.
    static let maximumHops = 64
    static let maximumDescendants = 4_096

    let uid: uid_t
    let table: [Int32: Row]
    let children: [Int32: [Int32]]
    private var full: [Int32: AgentProcessTable.Entry?] = [:]

    init(uid: uid_t, excluding me: Int32) {
        var table: [Int32: Row] = [:]
        for pid in AgentProcessTable.allPIDs() where pid != me {
            if let entry = AgentProcessTable.shortEntry(pid, uid: uid) { table[pid] = entry }
        }
        var children: [Int32: [Int32]] = [:]
        for (pid, row) in table { children[row.parent, default: []].append(pid) }
        self.uid = uid
        self.table = table
        self.children = children
    }

    mutating func fullEntry(_ pid: Int32) -> AgentProcessTable.Entry? {
        if let cached = full[pid] { return cached }
        let value = AgentProcessTable.entry(pid, uid: uid)
        full[pid] = value
        return value
    }

    /// Same tool below another agent: the same session when it is a wrapper (same folder and terminal, no shell
    /// between), merged into it; otherwise a delegated run (subagent), kept with its parent session.
    mutating func links(_ agents: [Int32: AgentProcessIdentity], directories: [Int32: String]) -> Links {
        var links = Links()
        for (pid, identity) in agents {
            guard let (ancestor, shellBetween) = nearestSameTool(pid, tool: identity.tool, agents: agents) else {
                continue
            }
            let wrapper = AgentProcessClassifier.isWrapper(
                sameFolder: directories[ancestor] == directories[pid], sameTerminal: sameTerminal(pid, ancestor),
                shellBetween: shellBetween)
            if wrapper { links.mergedInto[pid] = ancestor } else { links.parentAgent[pid] = ancestor }
        }
        // A delegated run names the session it came from, not that session's inner wrapper process.
        for (pid, parent) in links.parentAgent {
            links.parentAgent[pid] = Self.root(of: parent, mergedInto: links.mergedInto)
        }
        return links
    }

    /// `pid`'s readable descendants that are not sessions themselves, depth first and bounded. An unreadable process
    /// (it exited mid-scan) hides its subtree.
    mutating func descendants(
        of pid: Int32, excluding sessions: Set<Int32>
    ) -> [(pid: Int32, entry: AgentProcessTable.Entry)] {
        var result: [(pid: Int32, entry: AgentProcessTable.Entry)] = []
        var queue = children[pid] ?? []
        var visited: Set<Int32> = [pid]
        while let child = queue.popLast(), visited.count < Self.maximumDescendants {
            guard visited.insert(child).inserted, !sessions.contains(child), let entry = fullEntry(child) else {
                continue
            }
            result.append((child, entry))
            queue.append(contentsOf: children[child] ?? [])
        }
        return result
    }

    static func root(of pid: Int32, mergedInto: [Int32: Int32]) -> Int32 {
        var root = pid
        var hops = 0
        while let up = mergedInto[root], hops < maximumHops {
            root = up
            hops += 1
        }
        return root
    }

    /// The closest ancestor that is an agent of `tool`, and whether a shell sits between it and `pid`.
    private func nearestSameTool(
        _ pid: Int32, tool: AgentTool, agents: [Int32: AgentProcessIdentity]
    ) -> (ancestor: Int32, shellBetween: Bool)? {
        var current = table[pid]?.parent ?? 0
        var hops = 0
        var shellBetween = false
        while current > 1, hops < Self.maximumHops, let row = table[current] {
            if let ancestor = agents[current] {
                if ancestor.tool == tool { return (current, shellBetween) }
            } else if !shellBetween, let path = AgentProcessTable.executablePath(current) {
                shellBetween = AgentProcessClassifier.isShell(path: path)
            }
            current = row.parent
            hops += 1
        }
        return nil
    }

    private mutating func sameTerminal(_ pid: Int32, _ other: Int32) -> Bool {
        let mine = fullEntry(pid)
        let theirs = fullEntry(other)
        return mine?.hasTerminal == theirs?.hasTerminal
            && (mine?.hasTerminal != true || mine?.terminalDevice == theirs?.terminalDevice)
    }
}

/// Per-process CPU between scans. A process seen before reports what it used since; a process that started since
/// the previous scan contributes all of its CPU; an older one first seen now only sets a baseline.
struct AgentCPUMeter {
    typealias Mark = (start: UInt64, nanoseconds: UInt64)

    let previous: [Int32: Mark]
    let previousScan: UInt64
    private(set) var seen: [Int32: Mark] = [:]

    init(previous: [Int32: Mark], previousScan: UInt64) {
        self.previous = previous
        self.previousScan = previousScan
    }

    mutating func seconds(_ pid: Int32, _ entry: AgentProcessTable.Entry) -> Double {
        guard let cpu = AgentProcessTable.cpuNanoseconds(pid) else { return 0 }
        return record(pid, start: entry.start, nanoseconds: cpu)
    }

    mutating func record(_ pid: Int32, start: UInt64, nanoseconds cpu: UInt64) -> Double {
        seen[pid] = (start, cpu)
        if let last = previous[pid], last.start == start {
            return cpu > last.nanoseconds ? Double(cpu - last.nanoseconds) / 1e9 : 0
        }
        return previousScan != 0 && start >= previousScan ? Double(cpu) / 1e9 : 0
    }
}
