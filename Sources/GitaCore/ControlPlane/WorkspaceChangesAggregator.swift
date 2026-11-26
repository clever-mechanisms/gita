import Foundation

public struct WorkspaceRepository: Sendable, Equatable, Identifiable {
    public var id: String { root.path }
    public let root: URL
    public let name: String
    public let colorIndex: Int
    public let tabColorRawValue: String?
    public let groupName: String?

    public init(
        root: URL, name: String? = nil, colorIndex: Int = 0, tabColorRawValue: String? = nil,
        groupName: String? = nil
    ) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.name = name ?? self.root.lastPathComponent
        self.colorIndex = colorIndex
        self.tabColorRawValue = tabColorRawValue
        self.groupName = groupName
    }
}

enum WorkspaceBatch {
    /// Preserve workspace order while admitting at most four repositories at a time.
    static func map<T: Sendable, U: Sendable>(_ items: [T], _ body: @escaping @Sendable (T) async -> U) async -> [U] {
        await withTaskGroup(of: (Int, U).self) { group in
            var next = 0
            var results: [(Int, U)] = []
            for index in items.indices.prefix(4) {
                group.addTask { (index, await body(items[index])) }
                next += 1
            }
            while let result = await group.next() {
                results.append(result)
                if next < items.count, !Task.isCancelled {
                    let index = next
                    next += 1
                    group.addTask { (index, await body(items[index])) }
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

public struct WorkspaceRepoChanges: Sendable, Equatable {
    public let repository: WorkspaceRepository
    public internal(set) var branch: String?
    public internal(set) var headSHA: String?
    public internal(set) var ahead = 0
    public internal(set) var behind = 0
    public internal(set) var changes: [FileChange] = []
    public internal(set) var operation: GitOperationState?
    public internal(set) var error: String?
    public var stagedCount: Int { changes.filter { $0.isStaged && !$0.isConflict }.count }
    public var unstagedCount: Int { changes.filter { $0.isUnstaged && !$0.isUntracked && !$0.isConflict }.count }
    public var untrackedCount: Int { changes.filter(\.isUntracked).count }
    public var conflictCount: Int { changes.filter(\.isConflict).count }
    public var canStageAll: Bool { error == nil && conflictCount == 0 && unstagedCount + untrackedCount > 0 }
}

public enum WorkspaceChangesState: Sendable, Equatable {
    case idle, loading
    case loaded([WorkspaceRepoChanges])
    case empty
    case failed(String)
}

public struct WorkspaceChangesAggregator: Sendable {
    public init() {}
    public func collect(_ repositories: [WorkspaceRepository]) async -> [WorkspaceRepoChanges] {
        await WorkspaceBatch.map(repositories) { repository in
            do { return try await inspect(repository, git: GitService(root: repository.root)) } catch {
                return WorkspaceRepoChanges(repository: repository, error: error.localizedDescription)
            }
        }
    }

    public func stageAll(in root: URL) async throws -> WorkspaceRepoChanges {
        try await stageAll(in: WorkspaceRepository(root: root))
    }

    public func stageAll(in repository: WorkspaceRepository) async throws -> WorkspaceRepoChanges {
        let git = GitService(root: repository.root)
        try await git.mutate { service in
            guard try await service.unmergedIndex().isEmpty else { throw GitError.unresolvedConflicts }
            _ = try await service.execute(["add", "--", "."], mutation: true)
        }
        return try await inspect(repository, git: git)
    }

    private func inspect(_ repository: WorkspaceRepository, git: GitService) async throws -> WorkspaceRepoChanges {
        async let status = git.controlPlaneStatus()
        async let operation = git.operationState()
        let value = try await status
        return try await WorkspaceRepoChanges(
            repository: repository, branch: value.branch, headSHA: value.head,
            ahead: value.ahead, behind: value.behind, changes: value.changes, operation: operation)
    }
}
