import Foundation

public struct GitReference: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable { case branch, remote, tag }
    public var name: String
    public var fullName: String
    public var commit: String
    public var kind: Kind
    public var isCurrent: Bool
    public var id: String { fullName }
    public init(name: String, fullName: String, commit: String, kind: Kind, isCurrent: Bool = false) {
        self.name = name
        self.fullName = fullName
        self.commit = commit
        self.kind = kind
        self.isCurrent = isCurrent
    }
}

extension GitReference.Kind {
    /// The namespace of this kind: `refs/heads/`, `refs/remotes/` or `refs/tags/`.
    var prefix: String {
        switch self {
        case .branch: "refs/heads/"
        case .remote: "refs/remotes/"
        case .tag: "refs/tags/"
        }
    }

    /// The kind whose namespace `fullName` is in; nil for any other reference.
    init?(fullName: String) {
        guard let kind = [Self.branch, .remote, .tag].first(where: { fullName.hasPrefix($0.prefix) }) else {
            return nil
        }
        self = kind
    }
}
