import Foundation

/// Further history pages read from one `git log` left running (`HistoryStream`).
extension GitService {
    /// The page of `scope` after `skip` commits of the validated `snapshot` history: from the running walk when it
    /// is exactly there, else from a walk started at `skip`. A stream is closed when its page fails and once it has
    /// been idle for `HistoryStream.idleLimit`. A page being read owns its stream (the actor can take another call
    /// meanwhile, which then starts a walk of its own).
    func streamedHistory(
        limit: Int, skip: Int, scope: HistoryScope, snapshot: HistoryKey
    ) async throws -> [GitCommit] {
        let count = min(max(limit, 1), Self.historyPageLimit)
        let start = ContinuousClock.now
        startWalk(start)
        defer { noteWalk(ContinuousClock.now - start, start: start) }
        let stream: HistoryStream
        if let running = historyStream, running.continues(snapshot, scope: scope, at: skip) {
            stream = running
            historyStream = nil
        } else {
            closeHistoryStream()
            let arguments =
                GitArguments.logRecord + ["--skip=\(try Self.gitSkip(skip))"] + (try await walkRevisions(scope))
                + ["--"]
            stream = try HistoryStream(
                try await gitRequest(arguments, outputLimit: Self.historyOutputLimit), snapshot: snapshot,
                scope: scope, position: skip)
        }
        do {
            let commits = try await stream.page(count, at: skip)
            if stream.phase == .streaming {
                closeHistoryStream()
                historyStream = stream
                closeWhenIdle(stream)
            } else {
                stream.close()
            }
            return commits
        } catch {
            stream.close()
            throw error
        }
    }

    func closeHistoryStream() {
        historyStream?.close()
        historyStream = nil
    }

    /// Closes `stream` if it is still unread `HistoryStream.idleLimit` from now.
    private func closeWhenIdle(_ stream: HistoryStream) {
        Task { [weak self] in
            try? await Task.sleep(for: HistoryStream.idleLimit)
            await self?.closeIdleStream(stream)
        }
    }

    func closeIdleStream(_ stream: HistoryStream, now: ContinuousClock.Instant = .now) {
        guard historyStream === stream, now - stream.lastUse >= HistoryStream.idleLimit else { return }
        closeHistoryStream()
    }
}
