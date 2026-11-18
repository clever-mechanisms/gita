import Foundation

/// Refreshing the stat data of a stale index.
///
/// Gita reads status with `--no-optional-locks`, so the index is never rewritten by its reads. When the index's
/// stat data is stale (right after a clone or a checkout by another tool, files written in the same second as the
/// index), every status compares file contents again: VS Code 0.88 s instead of 0.13 s, Kubernetes 0.47 s instead
/// of 0.16 s. `git update-index -q --refresh` records the current stat data once. It changes no staged content.
/// Whether `git update-index --refresh` pays in a repository. A refresh is judged by the first status read that
/// starts after it ends (one already running still compares the old stat data), against the status time before it;
/// a refresh that fails leaves the verdict as it was. `useless` holds for the service's life: a large checkout is
/// simply slow.
enum IndexRefreshTrial: Equatable {
    case allowed
    /// `update-index` is running: status reads meanwhile are not judged.
    case running
    case judging(before: Duration, since: ContinuousClock.Instant)
    case useless
}

extension GitService {
    /// A status read at least this slow is worth refreshing the index for.
    public static let slowStatus = Duration.milliseconds(250)
    /// One refresh per repository in this long, whatever the status takes.
    static let indexRefreshInterval = Duration.seconds(60)

    /// A refresh that leaves status at more than this share of its time did not help (a large checkout is simply
    /// slow): the index is then left alone.
    static let usefulRefresh = 0.8

    /// Records how long a status read took, and whether the refresh that ended before it started helped.
    func noteStatus(_ duration: Duration, startedAt start: ContinuousClock.Instant = .now) {
        if case .judging(let before, let since) = indexRefreshTrial, start >= since {
            indexRefreshTrial = duration > before * Self.usefulRefresh ? .useless : .allowed
        }
        lastStatusDuration = duration
    }

    /// Whether the last status read was slow, no refresh ran recently and no other Git process holds the index.
    public func indexRefreshWouldHelp(now: ContinuousClock.Instant = .now) -> Bool {
        guard indexRefreshTrial != .useless, lastStatusDuration >= Self.slowStatus, let indexDirectory else {
            return false
        }
        if let lastIndexRefresh, now - lastIndexRefresh < Self.indexRefreshInterval { return false }
        return !FileManager.default.fileExists(atPath: indexDirectory.appendingPathComponent("index.lock").path)
    }

    /// `git update-index -q --refresh`, after the app's own queued writes; a held index lock makes it a no-op. The
    /// repository's fsmonitor hook stays off, as for every read the app starts on its own, and so do its hooks
    /// (`post-index-change`): this upkeep is the app's, not something the user did.
    public func refreshIndex() async throws {
        lastIndexRefresh = .now
        let before = lastStatusDuration
        let previous: IndexRefreshTrial = indexRefreshTrial == .useless ? .useless : .allowed
        indexRefreshTrial = .running
        do {
            let root = try await repositoryRoot()
            let hardening = await FSMonitorHardening.shared.readOptions(root: root, runner: runner)
            try await mutate { service in
                _ = try await service.execute(
                    GitArguments.noHooks + hardening + ["update-index", "-q", "--refresh"], timeout: 120,
                    allowFailure: true, mutation: true)
            }
        } catch {
            indexRefreshTrial = previous
            throw error
        }
        indexRefreshTrial = .judging(before: before, since: .now)
        lastStatusDuration = .zero
    }
}
