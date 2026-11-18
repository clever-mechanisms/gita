import Foundation

/// The attributes that decide how a conflicted path is converted between the index and the working tree.
struct ConflictAttributes {
    static let names = ["conflict-marker-size", "working-tree-encoding", "filter", "text", "eol", "ident", "crlf"]
    static let defaultMarkerSize = 7
    private static let textEncodings: Set<String> = ["UNSPECIFIED", "UNSET", "UTF-8", "UTF8"]

    /// The raw `check-attr -z` output, part of the conflict's identity.
    var data: Data
    var markerSize: Int
    /// Only UTF-8 working files can be edited as text.
    var supportsTextEditing: Bool

    /// `git check-attr -z <names> -- path`: path, name and value per attribute, in order.
    init(checkAttr data: Data, path: String) throws {
        let fields = data.split(separator: GitOutput.nul, omittingEmptySubsequences: false)
        guard fields.count == Self.names.count * 3 + 1, fields.last?.isEmpty == true else { throw GitError.invalidPath }
        var values: [String: String] = [:]
        for (index, name) in Self.names.enumerated() {
            let offset = index * 3
            guard fields[offset].elementsEqual(path.utf8), fields[offset + 1].elementsEqual(name.utf8) else {
                throw GitError.invalidPath
            }
            values[name] = String(decoding: fields[offset + 2], as: UTF8.self)
        }
        self.data = data
        markerSize =
            values["conflict-marker-size"].flatMap(Int.init).flatMap { $0 > 0 && $0 <= Int32.max ? $0 : nil }
            ?? Self.defaultMarkerSize
        supportsTextEditing = Self.textEncodings.contains(
            values["working-tree-encoding"]?.uppercased() ?? "UNSPECIFIED")
    }

    /// Only marker lines are rejected: ordinary source containing runs of '=' remains editable. A path can override
    /// Git's default seven-character size.
    func hasConflictMarkers(_ text: String) -> Bool {
        let markers: Set<UInt8> = [UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "|")]
        let separators: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r")]
        return text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let bytes = line.utf8
            guard let marker = bytes.first, markers.contains(marker) else { return false }
            let run = bytes.prefix(while: { $0 == marker }).count
            guard run >= markerSize else { return false }
            return bytes.dropFirst(run).first.map(separators.contains) ?? true
        }
    }

    /// Optional filters may fail with exit status zero and return unconverted bytes. Git's informational EOL
    /// warning is permitted; any other diagnostic means the conversion is not trustworthy.
    static func hasUnsafeConversionDiagnostic(_ data: Data) -> Bool {
        let suffixes = [
            "', LF will be replaced by CRLF the next time Git touches it",
            "', CRLF will be replaced by LF the next time Git touches it",
        ]
        return data.split(separator: GitOutput.lineFeed).contains { line in
            let message = String(decoding: line, as: UTF8.self)
            return !message.hasPrefix("warning: in the working copy of '")
                || !suffixes.contains(where: message.hasSuffix)
        }
    }
}
