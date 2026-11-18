import Foundation

/// One `for-each-ref` record of a reviewed reference. `bytes` is the exact record, part of the review identity:
/// it also carries the upstream's remote name and remote ref, which a change of tracking alters.
struct ReferenceRecord {
    static let format =
        "%(refname)%00%(objectname)%00%(objecttype)%00%(symref)%00%(upstream)%00%(upstream:remotename)%00"
        + "%(upstream:remoteref)%00"
    private static let fieldCount = 8

    var bytes: Data
    var objectID: String
    var objectType: String
    var symbolicTarget: String
    var upstream: String

    /// The record whose refname is exactly `fullName`; nil when there is none.
    static func parse(_ output: Data, fullName: String) throws -> Self? {
        for line in output.split(separator: GitOutput.lineFeed) {
            let fields = line.split(separator: GitOutput.nul, omittingEmptySubsequences: false)
            guard fields.count == fieldCount, fields[0].elementsEqual(fullName.utf8) else { continue }
            let strings = fields.compactMap { String(data: Data($0), encoding: .utf8) }
            guard strings.count == fieldCount, GitParsers.isObjectID(strings[1]) else {
                throw GitError.invalidReference
            }
            return Self(
                bytes: Data(line), objectID: strings[1], objectType: strings[2], symbolicTarget: strings[3],
                upstream: strings[4])
        }
        return nil
    }
}
