import Foundation

/// `ls-files --stage -z` and `ls-tree -r -z` records, keyed by path.
enum TreeEntries {
    struct Entry {
        var mode: GitFileMode
    }

    static func parse(_ data: Data, index: Bool) throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        for record in data.split(separator: GitOutput.nul) {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")),
                let path = String(data: Data(record[record.index(after: tab)...]), encoding: .utf8)
            else { throw GitError.invalidPath }
            try GitInput.validateComponents(path)
            let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3, let mode = GitFileMode(rawValue: String(fields[0])) else {
                throw GitError.invalidPath
            }
            if index, fields[2] != "0" { throw GitError.unresolvedConflicts }
            let objectID = String(fields[index ? 1 : 2])
            guard GitParsers.isObjectID(objectID), result[path] == nil else { throw GitError.invalidPath }
            result[path] = Entry(mode: mode)
        }
        return result
    }

    /// `ls-files --others --directory -z`: directories end in "/".
    static func otherPaths(_ data: Data) throws -> [String] {
        try data.split(separator: GitOutput.nul).map { bytes in
            guard let path = String(data: Data(bytes), encoding: .utf8) else { throw GitError.invalidPath }
            try GitInput.validateComponents(path.hasSuffix("/") ? String(path.dropLast()) : path)
            return path
        }
    }
}
