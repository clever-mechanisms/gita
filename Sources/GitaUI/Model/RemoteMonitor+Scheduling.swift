import Foundation
import GitaCore

/// Queueing, concurrency capping, stagger, Tier 1 `ls-remote` execution and Tier 2 auto-fetch for `RemoteMonitor`.
extension RemoteMonitor {
    func movedKeys(using key: (URL?) -> String?) -> (roots: Set<String>, checkouts: Set<String>) {
        var roots = Set<String>()
        var checkouts = Set<String>()
        for entry in entries.values {
            guard let delta = entry.last, delta.movedCount > 0 else { continue }
            if let entryKey = key(entry.root) {
                roots.insert(entryKey)
                if delta.currentUpstreamMoved { checkouts.insert(entryKey) }
            }
            if let first = entry.snapshot?.worktrees.first, !first.isBare,
                let mainKey = key(URL(fileURLWithPath: first.path))
            {
                roots.insert(mainKey)
            }
        }
        return (roots, checkouts)
    }

    func enqueue(id: String, allowAutoFetch: Bool, allowStagger: Bool) {
        guard inFlight[id] == nil, !queue.contains(where: { $0.id == id }) else { return }
        queue.append(QueuedRemoteCheck(id: id, allowAutoFetch: allowAutoFetch, allowStagger: allowStagger))
    }

    func drainQueue() {
        while inFlight.count < RemoteCheckPolicy.maxConcurrentChecks, !queue.isEmpty {
            let next = queue.removeFirst()
            guard entries[next.id] != nil, inFlight[next.id] == nil else { continue }
            let delay = next.allowStagger ? environment.staggerDelay(staggerIndex) : 0
            staggerIndex += 1
            launchCheck(for: next.id, allowAutoFetch: next.allowAutoFetch, staggerDelay: delay)
        }
        if inFlight.isEmpty { staggerIndex = 0 }
    }

    private func launchCheck(for id: String, allowAutoFetch: Bool, staggerDelay: TimeInterval) {
        guard var entry = entries[id] else { return }
        let checkID = UUID()
        inFlight[id] = checkID
        let task = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.finishInFlight(id: id, operationID: checkID) } }
            do {
                try await self?.environment.sleep(staggerDelay)
                try Task.checkCancellation()
                await self?.executeCheck(id: id, checkID: checkID, allowAutoFetch: allowAutoFetch)
            } catch {}
        }
        entry.phase = .checking(checkID, task)
        store(entry, id: id)
    }

    private func executeCheck(id: String, checkID: UUID, allowAutoFetch: Bool) async {
        guard let entry = entries[id], case .checking(let activeID, _) = entry.phase, activeID == checkID else {
            return
        }
        let service = entry.service
        let snapshot = entry.snapshot
        let settings = RemoteUpdateSettings.load(from: entry.defaults)
        let remotes = await eligibleRemotes(service: service, snapshot: snapshot, pausedAuth: entry.pausedAuthRemotes)
        if let terminal = terminalStateIfNoneEligible(remotes) {
            applyTerminalState(terminal, id: id, expectedCheckID: checkID)
            return
        }
        let result = await performChecks(
            remotes: remotes.accepted, service: service, snapshot: snapshot, now: environment.now())
        guard let currentEntry = entries[id], case .checking(let active, _) = currentEntry.phase,
            active == checkID
        else { return }
        applyCheckOutcome(result, id: id, settings: settings, allowAutoFetch: allowAutoFetch)
    }

    private func eligibleRemotes(
        service: GitService, snapshot: RepositorySnapshot?, pausedAuth: Set<String>
    ) async -> (accepted: [String], unsupportedCount: Int, pausedAuthCount: Int) {
        let urls: [String: String] =
            if let snapshot {
                snapshot.remoteURLs
            } else {
                await service.remoteURLs()
            }
        var accepted: [String] = []
        var unsupported = 0
        var paused = 0
        for (name, url) in urls.sorted(by: { $0.key < $1.key }) {
            if !RemoteURLPolicy.isAccepted(url) {
                unsupported += 1
            } else if pausedAuth.contains(name) {
                paused += 1
            } else {
                accepted.append(name)
            }
        }
        return (accepted, unsupported, paused)
    }

    private func terminalStateIfNoneEligible(
        _ remotes: (accepted: [String], unsupportedCount: Int, pausedAuthCount: Int)
    ) -> RemoteCheckState.Phase? {
        guard remotes.accepted.isEmpty else { return nil }
        if remotes.pausedAuthCount > 0 {
            return .backingOff(until: .distantFuture, reason: .authenticationRequired)
        }
        if remotes.unsupportedCount > 0 {
            return .backingOff(until: .distantFuture, reason: .unsupportedURL)
        }
        return .off
    }

    private func applyTerminalState(_ state: RemoteCheckState.Phase, id: String, expectedCheckID: UUID) {
        guard var entry = entries[id], case .checking(let active, _) = entry.phase, active == expectedCheckID else {
            return
        }
        entry.phase = state
        if case .off = state { entry.last = nil }
        store(entry, id: id)
    }

    private func performChecks(
        remotes: [String], service: GitService, snapshot: RepositorySnapshot?, now: Date
    ) async -> CheckAggregate {
        let upstreams = (try? await service.branchUpstreams()) ?? [:]
        let references = snapshot?.references ?? []
        let currentBranch = snapshot?.branch
        var aggregate = CheckAggregate(checkedAt: now)
        for remote in remotes {
            if Task.isCancelled { return aggregate }
            do {
                let delta = try await environment.checkRemote(
                    service, remote, upstreams, references, currentBranch, now)
                aggregate.recordSuccess(delta)
            } catch is CancellationError {
                return aggregate
            } catch let error as RemoteCheckError {
                aggregate.recordFailure(remote: remote, failure: error.failure)
            } catch {
                aggregate.recordFailure(remote: remote, failure: .unreachable)
            }
        }
        return aggregate
    }

    private func applyCheckOutcome(
        _ outcome: CheckAggregate, id: String, settings: RemoteUpdateSettings, allowAutoFetch: Bool
    ) {
        guard var entry = entries[id] else { return }
        entry.pausedAuthRemotes.formUnion(outcome.authFailures)
        guard outcome.successCount > 0 else {
            backOff(outcome.lastFailure ?? .unreachable, entry: &entry)
            store(entry, id: id)
            return
        }
        entry.failures = 0
        let delta = outcome.delta
        entry.last = delta
        let fetchAllowed =
            allowAutoFetch
            && RemoteCheckPolicy.shouldFetch(delta: delta, settings: settings, network: networkStatus)
            && !entry.isMutating
        if fetchAllowed {
            startAutoFetch(id: id, entry: &entry, delta: delta, settings: settings)
        } else {
            let next = environment.now().addingTimeInterval(settings.cadence.interval)
            entry.phase = .waiting(next: next)
            store(entry, id: id)
        }
    }

    private func backOff(_ reason: RemoteCheckFailure, entry: inout RemoteEntry) {
        var until = Date.distantFuture
        if reason != .authenticationRequired && reason != .unsupportedURL {
            entry.failures += 1
            let delay = RemoteCheckPolicy.nextDelay(failures: entry.failures, jitterFraction: environment.jitter())
            until = environment.now().addingTimeInterval(delay)
        }
        entry.phase = .backingOff(until: until, reason: reason)
    }

    private func startAutoFetch(
        id: String, entry: inout RemoteEntry, delta: RemoteDelta, settings: RemoteUpdateSettings
    ) {
        let remotes = delta.movedRemotes
        let fetchID = UUID()
        inFlight[id] = fetchID
        let service = entry.service
        let fetchTask = Task { [weak self] in
            guard let self else { return }
            await self.runAutoFetch(id: id, fetchID: fetchID, remotes: remotes, service: service, settings: settings)
        }
        entry.phase = .fetching(fetchID, fetchTask)
        store(entry, id: id)
    }

    private func runAutoFetch(
        id: String, fetchID: UUID, remotes: [String], service: GitService, settings: RemoteUpdateSettings
    ) async {
        defer { Task { @MainActor [weak self] in self?.finishInFlight(id: id, operationID: fetchID) } }
        var fetched: [String] = []
        var fetchFailure: RemoteCheckFailure?
        for remote in remotes {
            if Task.isCancelled { return }
            do {
                try await environment.backgroundFetch(service, remote)
                fetched.append(remote)
            } catch is CancellationError {
                return
            } catch let error as RemoteCheckError {
                if error.failure == .authenticationRequired, inFlight[id] == fetchID, var entry = entries[id] {
                    entry.pausedAuthRemotes.insert(error.remote ?? remote)
                    store(entry, id: id)
                }
                fetchFailure = error.failure
            } catch {
                fetchFailure = .unreachable
            }
        }
        applyAutoFetchOutcome(
            id: id, fetchID: fetchID, fetched: fetched, fetchFailure: fetchFailure, settings: settings)
    }

    private func applyAutoFetchOutcome(
        id: String, fetchID: UUID, fetched: [String], fetchFailure: RemoteCheckFailure?, settings: RemoteUpdateSettings
    ) {
        guard var entry = entries[id], case .fetching(let active, _) = entry.phase,
            active == fetchID
        else { return }
        let now = environment.now()
        if !fetched.isEmpty {
            entry.lastFetchAt = now
            entry.failures = 0
            entry.last?.clearing(remotes: fetched, checkedAt: now)
        }
        if let fetchFailure, fetched.isEmpty {
            backOff(fetchFailure, entry: &entry)
        } else {
            entry.phase = .waiting(next: now.addingTimeInterval(settings.cadence.interval))
        }
        store(entry, id: id)
        if !fetched.isEmpty { notifyAutoFetched(entry: entry) }
    }

    private func finishInFlight(id: String, operationID: UUID) {
        guard inFlight[id] == operationID else { return }
        inFlight.removeValue(forKey: id)
        if var entry = entries[id], entry.pendingManualCheck, !entry.state.isBusy {
            entry.pendingManualCheck = false
            store(entry, id: id)
            enqueue(id: id, allowAutoFetch: true, allowStagger: false)
        }
        drainQueue()
    }
}

private struct CheckAggregate {
    var delta: RemoteDelta
    var successCount = 0
    var authFailures: Set<String> = []
    var lastFailure: RemoteCheckFailure?

    init(checkedAt: Date) {
        delta = RemoteDelta(checkedAt: checkedAt)
    }

    mutating func recordSuccess(_ remoteDelta: RemoteDelta) {
        successCount += 1
        delta.moved.merge(remoteDelta.moved) { _, new in new }
        delta.gone.formUnion(remoteDelta.gone)
        if remoteDelta.currentUpstreamMoved {
            delta.currentUpstreamMoved = true
            delta.currentUpstreamKey = remoteDelta.currentUpstreamKey
        }
    }

    mutating func recordFailure(remote: String, failure: RemoteCheckFailure) {
        if failure == .authenticationRequired { authFailures.insert(remote) }
        lastFailure = failure
    }
}
