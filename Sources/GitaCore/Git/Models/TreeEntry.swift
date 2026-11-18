import Foundation

public struct TreeEntry: Identifiable, Sendable, Hashable {
    public var path: String
    public var kind: String
    public var objectID: String
    public var id: String { path }
    public init(path: String, kind: String, objectID: String) {
        self.path = path
        self.kind = kind
        self.objectID = objectID
    }
}

extension TreeEntry {
    /// A folder (`ls-tree` type `tree`), listed before files.
    var isTree: Bool { kind == "tree" }
}
