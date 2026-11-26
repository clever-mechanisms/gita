import Foundation

/// Verification/checkout status prefix reported by `git submodule status`.
public enum GitSubmoduleStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    case clean
    case uninitialized
    case modified
    case conflict

    public init(statusPrefix: Character) {
        switch statusPrefix {
        case "-":
            self = .uninitialized
        case "+":
            self = .modified
        case "U":
            self = .conflict
        default:
            self = .clean
        }
    }

    public var displayTitle: String {
        switch self {
        case .clean:
            return String(localized: "Clean")
        case .uninitialized:
            return String(localized: "Uninitialized")
        case .modified:
            return String(localized: "Modified")
        case .conflict:
            return String(localized: "Conflict")
        }
    }

    public var detailDescription: String {
        switch self {
        case .clean:
            return String(localized: "Checked out at the recorded commit.")
        case .uninitialized:
            return String(localized: "Submodule is not initialized yet.")
        case .modified:
            return String(localized: "Checked out commit differs from the recorded commit.")
        case .conflict:
            return String(localized: "Submodule has merge conflicts.")
        }
    }
}

/// A Git submodule registered in `.gitmodules` and/or reported by `git submodule status`.
public struct GitSubmodule: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let sha: String
    public let status: GitSubmoduleStatus
    public let url: String?
    public let branch: String?
    public let describe: String?

    public init(
        path: String,
        name: String,
        sha: String,
        status: GitSubmoduleStatus,
        url: String? = nil,
        branch: String? = nil,
        describe: String? = nil
    ) {
        self.path = path
        self.name = name
        self.sha = sha
        self.status = status
        self.url = url
        self.branch = branch
        self.describe = describe
    }

    public var shortSHA: String { String(sha.prefix(7)) }

    public func resolvedURL(in repositoryRoot: URL) -> URL {
        repositoryRoot.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }
}

/// Lifecycle state for loading and mutating submodules.
/// Mutation failures keep the loaded submodule list intact alongside `error` so the table stays usable.
public enum SubmoduleLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded([GitSubmodule], error: String? = nil)
    case mutating(action: String, submodules: [GitSubmodule])
    case failed(String)

    public var isLoading: Bool {
        switch self {
        case .loading: true
        default: false
        }
    }

    public var isMutating: Bool {
        switch self {
        case .mutating: true
        default: false
        }
    }

    public var isBusy: Bool { isLoading || isMutating }

    public var submodules: [GitSubmodule] {
        switch self {
        case .loaded(let items, _), .mutating(_, let items): items
        case .idle, .loading, .failed: []
        }
    }

    public var activeAction: String? {
        switch self {
        case .mutating(let action, _): action
        default: nil
        }
    }

    public var errorMessage: String? {
        switch self {
        case .failed(let message): message
        case .loaded(_, let error): error
        default: nil
        }
    }
}
