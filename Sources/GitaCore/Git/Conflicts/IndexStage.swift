import Foundation

/// One stage (1 base, 2 ours, 3 theirs) of a conflicted index entry.
struct IndexStage {
    var mode: GitFileMode
    var objectID: String

    /// `git ls-files --unmerged --stage -z -- path`, keyed by stage number.
    static func parse(_ data: Data, path: String) throws -> [Int: Self] {
        var result: [Int: Self] = [:]
        for record in data.split(separator: GitOutput.nul) {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")),
                record[record.index(after: tab)...].elementsEqual(path.utf8)
            else { throw GitError.invalidPath }
            let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3, let mode = GitFileMode(rawValue: String(fields[0])),
                GitParsers.isObjectID(String(fields[1])), let stage = Int(fields[2]), (1...3).contains(stage),
                result[stage] == nil
            else { throw GitError.noConflict }
            result[stage] = Self(mode: mode, objectID: String(fields[1]))
        }
        return result
    }
}
