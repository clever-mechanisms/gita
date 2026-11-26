import Foundation

public struct WorkspaceTimelineEvent: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case commit(sha: String, author: String)
        case pullRequest(number: Int, state: SignalState, author: String?)
        case deployment(environment: String, state: SignalState, url: URL?)
    }
    public let id: String
    public let repository: WorkspaceRepository
    public let timestamp: Date
    public let title: String
    public let subtitle: String
    public let kind: Kind
    public let state: SignalState
    public let branch: String?
    public let commitSHA: String?
    public let url: URL?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.repository == rhs.repository
            && lhs.timestamp == rhs.timestamp
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.kind == rhs.kind
            && lhs.state == rhs.state
            && lhs.branch == rhs.branch
            && lhs.commitSHA == rhs.commitSHA
            && lhs.url == rhs.url
    }
}

public struct WorkspaceTimelineSource: Sendable {
    public let repository: WorkspaceRepository
    public let commits: [GitCommit]
    public let reports: [ProviderReport]
    public init(repository: WorkspaceRepository, commits: [GitCommit], reports: [ProviderReport]) {
        self.repository = repository
        self.commits = commits
        self.reports = reports
    }
}

public enum WorkspaceTimelineState: Equatable, Sendable {
    case idle, loading
    case loaded([WorkspaceTimelineEvent])
    case empty
    case failed(String)
}

public struct WorkspaceTimelineBuilder: Sendable {
    public init() {}
    public func build(_ sources: [WorkspaceTimelineSource]) -> [WorkspaceTimelineEvent] {
        var events: [WorkspaceTimelineEvent] = []
        for source in sources {
            let repo = source.repository
            events += source.commits.map {
                .init(
                    id: repo.id + ":commit:" + $0.id, repository: repo, timestamp: $0.date, title: $0.subject,
                    subtitle: $0.author, kind: .commit(sha: $0.id, author: $0.author), state: .neutral,
                    branch: nil, commitSHA: $0.id, url: nil)
            }
            for report in source.reports {
                events += report.items.compactMap { event($0, repo: repo) }
            }
        }
        var seen = Set<String>()
        let sorted = events.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp
        }
        var result: [WorkspaceTimelineEvent] = []
        for event in sorted where seen.insert(event.id).inserted {
            result.append(event)
            if result.count == 300 { break }
        }
        return result
    }

    private func event(_ item: ProviderItem, repo: WorkspaceRepository) -> WorkspaceTimelineEvent? {
        let kind: WorkspaceTimelineEvent.Kind
        let date: Date?
        if item.provider == .github, let pr = item.pullRequest {
            kind = .pullRequest(number: pr.number, state: item.state, author: pr.author)
            date = item.date ?? pr.mergedAt ?? pr.createdAt
        } else if item.provider == .vercel, item.kind == .deployment || item.deployment != nil {
            kind = .deployment(
                environment: item.deployment?.environment.name ?? String(localized: "Unknown"),
                state: item.state, url: item.url)
            date = item.date ?? item.startedAt
        } else {
            return nil
        }
        guard let date else { return nil }
        return .init(
            id: repo.id + ":" + item.provider.rawValue + ":" + item.id, repository: repo,
            timestamp: date, title: item.title, subtitle: item.detail, kind: kind, state: item.state,
            branch: item.branch, commitSHA: item.commit, url: item.url)
    }

    public func collect(
        _ repositories: [WorkspaceRepository], reports: [URL: [ProviderReport]]
    ) async throws -> [WorkspaceTimelineEvent] {
        let byPath = Dictionary(
            reports.map { ($0.key.standardizedFileURL.resolvingSymlinksInPath().path, $0.value) }, uniquingKeysWith: +)
        return try await collect(repositories) { repo in
            let reports = byPath[repo.id] ?? []
            do {
                let snapshot = try await GitService(root: repo.root).snapshot(limit: 300)
                return WorkspaceTimelineSource(repository: repo, commits: snapshot.commits, reports: reports)
            } catch {
                guard !reports.isEmpty else { throw error }
                return WorkspaceTimelineSource(repository: repo, commits: [], reports: reports)
            }
        }
    }

    private func collect(
        _ repositories: [WorkspaceRepository],
        source: @escaping @Sendable (WorkspaceRepository) async throws -> WorkspaceTimelineSource
    ) async throws -> [WorkspaceTimelineEvent] {
        let sources = await WorkspaceBatch.map(repositories) { repo -> Result<WorkspaceTimelineSource, Error> in
            do { return .success(try await source(repo)) } catch { return .failure(error) }
        }
        try Task.checkCancellation()
        let available = sources.compactMap { try? $0.get() }
        if available.isEmpty, let first = sources.first { _ = try first.get() }
        return build(available)
    }
}
