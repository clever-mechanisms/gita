import Foundation

public struct GitCommit: Identifiable, Sendable, Hashable {
    public var id: String
    public var parents: [String]
    public var subject: String
    public var author: String
    public var email: String
    public var date: Date
    public var decorations: [String]
    public init(
        id: String, parents: [String], subject: String, author: String, email: String = "", date: Date,
        decorations: [String] = []
    ) {
        self.id = id
        self.parents = parents
        self.subject = subject
        self.author = author
        self.email = email
        self.date = date
        self.decorations = decorations
    }
}
