import Foundation

public struct ConflictVersion: Sendable {
    public var objectID: String
    public var mode: GitFileMode
    public var text: String?
    public var byteCount: Int
    public init(objectID: String, mode: GitFileMode, text: String?, byteCount: Int) {
        self.objectID = objectID
        self.mode = mode
        self.text = text
        self.byteCount = byteCount
    }
}

public struct ConflictDocument: Sendable {
    public var path: String
    public var base: ConflictVersion?
    public var ours: ConflictVersion?
    public var theirs: ConflictVersion?
    public var workingText: String?
    public var workingExists: Bool
    public var isEditable: Bool
    public var fingerprint: String
    public init(
        path: String, base: ConflictVersion?, ours: ConflictVersion?, theirs: ConflictVersion?, workingText: String?,
        workingExists: Bool, isEditable: Bool, fingerprint: String
    ) {
        self.path = path
        self.base = base
        self.ours = ours
        self.theirs = theirs
        self.workingText = workingText
        self.workingExists = workingExists
        self.isEditable = isEditable
        self.fingerprint = fingerprint
    }
}

public enum ConflictResolution: Sendable {
    case base, ours, theirs
    case edited(String)
}
