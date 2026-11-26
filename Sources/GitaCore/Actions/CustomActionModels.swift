import Foundation

public enum CustomActionScope: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case repository, commit, branch, file, worktree

    public var localizedTitle: String {
        switch self {
        case .repository: String(localized: "Repository")
        case .commit: String(localized: "Commit")
        case .branch: String(localized: "Branch")
        case .file: String(localized: "File")
        case .worktree: String(localized: "Worktree")
        }
    }

    public var symbolName: String {
        switch self {
        case .repository: "folder"
        case .commit: "circle.inset.filled"
        case .branch: "arrow.triangle.branch"
        case .file: "doc"
        case .worktree: "folder.badge.gearshape"
        }
    }

    public var supportedPlaceholders: [String] {
        let common = ["$REPO_ROOT", "$REMOTE_URL"]
        switch self {
        case .repository: return common
        case .commit: return ["$SHA"] + common
        case .branch: return ["$BRANCH"] + common
        case .file: return ["$FILE"] + common
        case .worktree: return ["$WORKTREE"] + common
        }
    }
}

public struct CustomAction: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var scope: CustomActionScope
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var showsOutput = true
    public var confirmsBeforeRun = true
    public var timeoutSeconds: TimeInterval = 60

    public init(
        id: UUID = UUID(), name: String, scope: CustomActionScope = .repository,
        executable: String, arguments: [String] = [], workingDirectory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, scope, executable, arguments, workingDirectory, showsOutput, confirmsBeforeRun, timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        scope = try container.decodeIfPresent(CustomActionScope.self, forKey: .scope) ?? .repository
        executable = try container.decodeIfPresent(String.self, forKey: .executable) ?? ""
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        showsOutput = try container.decodeIfPresent(Bool.self, forKey: .showsOutput) ?? true
        confirmsBeforeRun = try container.decodeIfPresent(Bool.self, forKey: .confirmsBeforeRun) ?? true
        timeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds) ?? 60
    }
}

public struct CustomActionContext: Equatable, Sendable {
    public var repositoryRoot: URL
    public var worktreePath: URL?
    public var commitSHA: String?
    public var branch: String?
    public var filePath: String?
    public var remoteURL: String?

    public init(
        repositoryRoot: URL, worktreePath: URL? = nil, commitSHA: String? = nil,
        branch: String? = nil, filePath: String? = nil, remoteURL: String? = nil
    ) {
        self.repositoryRoot = repositoryRoot
        self.worktreePath = worktreePath
        self.commitSHA = commitSHA
        self.branch = branch
        self.filePath = filePath
        self.remoteURL = remoteURL
    }
}

public struct ResolvedCustomActionCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let directory: URL
    public var displayCommand: String {
        ([executable] + arguments).map { GitService.redactingCredentials($0).debugDescription }.joined(separator: " ")
    }
    public var displayArguments: [String] {
        ([executable] + arguments).map { GitService.redactingCredentials($0) }
    }
}

public struct CustomActionRunOutput: Equatable, Sendable {
    public let command: ResolvedCustomActionCommand
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let duration: TimeInterval
    public var succeeded: Bool { exitCode == 0 }
}

public enum CustomActionRunState: Equatable, Sendable {
    case idle
    case running(command: ResolvedCustomActionCommand)
    case finished(CustomActionRunOutput)
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var output: CustomActionRunOutput? {
        if case .finished(let output) = self { return output }
        return nil
    }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

public enum CustomActionError: Error, LocalizedError, Equatable, Sendable {
    case emptyName, invalidExecutable, invalidArgument, invalidTimeout, shellCommand, missingAction, duplicateID
    case missingPlaceholder(String)
    case unsupportedPlaceholder(String, scope: CustomActionScope)
    case execution(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "Enter an action name.")
        case .invalidExecutable: String(localized: "Enter an executable without control characters.")
        case .invalidArgument: String(localized: "Arguments and paths cannot contain invalid characters.")
        case .invalidTimeout: String(localized: "Enter a finite timeout greater than zero.")
        case .shellCommand: String(localized: "Choose the executable directly. Shell command strings cannot run.")
        case .missingAction: String(localized: "The selected action no longer exists.")
        case .duplicateID: String(localized: "Each action must have a unique ID.")
        case .missingPlaceholder(let key): String(localized: "No value is available for \(key) in this context.")
        case .unsupportedPlaceholder(let key, let scope):
            String(localized: "\(key) is not available for the \(scope.localizedTitle) scope.")
        case .execution(let reason): String(localized: "Could not run the action. \(reason)")
        }
    }
}
