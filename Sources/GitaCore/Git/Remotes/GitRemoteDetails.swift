import Foundation

/// Only sanitized URLs leave the service. A nil editableURL means the current
/// fetch configuration cannot be represented by the one-URL editor.
public struct GitRemoteDetails: Identifiable, Sendable, Hashable {
    public let name: String
    public let fetchURLs: [String]
    public let pushURLs: [String]
    public let editableURL: String?
    public let mutationRestriction: String?
    public let identity: String
    public var id: String { name }
    public init(
        name: String, fetchURLs: [String], pushURLs: [String], editableURL: String?, mutationRestriction: String? = nil,
        identity: String
    ) {
        self.name = name
        self.fetchURLs = fetchURLs
        self.pushURLs = pushURLs
        self.editableURL = editableURL
        self.mutationRestriction = mutationRestriction
        self.identity = identity
    }
}
