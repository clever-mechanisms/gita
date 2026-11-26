import Foundation

public struct GitStash: Identifiable, Sendable, Hashable {
    public var ref: String
    public var subject: String
    public var commitID: String?
    public var id: String { ref }
    public init(ref: String, subject: String, commitID: String? = nil) {
        self.ref = ref
        self.subject = subject
        self.commitID = commitID
    }
}
