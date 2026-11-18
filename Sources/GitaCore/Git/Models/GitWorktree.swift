import Foundation

public struct GitWorktree: Identifiable, Sendable, Hashable {
    public var path: String
    /// The checked-out branch's name; nil while HEAD is detached and in a bare repository.
    public var branch: String?
    public var head: String
    public var isBare: Bool
    public var isLocked: Bool
    public var isPrunable: Bool
    public var id: String { path }
    public init(
        path: String, branch: String?, head: String, isBare: Bool = false, isLocked: Bool = false,
        isPrunable: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isBare = isBare
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}
