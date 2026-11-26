import Foundation
import GitaCore

/// Core stores a first-parent chain per session. Remember the keys returned by successful hook captures
/// so a reopened recorder can combine those chains with manual snapshots.
@MainActor
struct FlightHistory {
    private static var revision: UInt = 0
    let service: FlightRecorderService
    let root: URL

    private var registry: String {
        "Gita.AgentControl.FlightHistory." + root.standardizedFileURL.resolvingSymlinksInPath().path
    }
    private var keys: [String] { UserDefaults.standard.stringArray(forKey: registry) ?? [] }

    func remember(_ key: String) {
        Self.revision &+= 1
        guard key != "default", !keys.contains(key) else { return }
        UserDefaults.standard.set(keys + [key], forKey: registry)
    }

    func snapshots() async throws -> [FlightSnapshot] {
        var turns: [FlightSnapshot] = []
        for key in ["default"] + keys {
            try Task.checkCancellation()
            let revision = Self.revision
            let snapshots = try await service.listSnapshots(in: root, key: key)
            if snapshots.isEmpty { try await forget(key, observedAt: revision) }
            turns += snapshots
        }
        return turns.sorted { ($0.createdAt, $0.sequence, $0.id) < ($1.createdAt, $1.sequence, $1.id) }
    }

    private func forget(_ key: String, observedAt revision: UInt) async throws {
        guard key != "default" else { return }
        var observed = revision
        while observed != Self.revision {
            observed = Self.revision
            if try await !service.listSnapshots(in: root, key: key, limit: 1).isEmpty { return }
        }
        let remaining = keys.filter { $0 != key }
        if remaining.isEmpty {
            UserDefaults.standard.removeObject(forKey: registry)
        } else {
            UserDefaults.standard.set(remaining, forKey: registry)
        }
    }

    func clear() async throws {
        for key in ["default"] + keys {
            try Task.checkCancellation()
            let revision = Self.revision
            try await service.clearSnapshots(in: root, key: key)
            try await forget(key, observedAt: revision)
        }
    }
}
