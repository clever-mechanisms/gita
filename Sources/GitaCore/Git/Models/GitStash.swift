import Foundation

public struct GitStash: Identifiable, Sendable, Hashable {
    public var ref: String
    public var subject: String
    public var id: String { ref }
    public init(ref: String, subject: String) {
        self.ref = ref
        self.subject = subject
    }
}
