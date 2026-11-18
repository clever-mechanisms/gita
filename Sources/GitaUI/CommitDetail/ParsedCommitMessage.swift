import Foundation

/// A commit message split into its subject, body and `Co-Authored-By` trailers (shown without the email).
struct ParsedCommitMessage: Equatable {
    private static let coAuthor = "Co-Authored-By:"

    var subject: String
    var body: String
    var trailers: [String]

    init(_ message: String) {
        var lines = message.components(separatedBy: "\n")
        subject = lines.isEmpty ? "" : lines.removeFirst()
        trailers = []
        var body: [String] = []
        for line in lines {
            if let who = Self.coAuthor(in: line) {
                trailers.append("Co-Authored-By: \(who)")
            } else {
                body.append(line)
            }
        }
        self.body = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The co-author's name when `line` is a `Co-Authored-By` trailer.
    private static func coAuthor(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: coAuthor, options: [.caseInsensitive, .anchored]) else { return nil }
        let who = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let email = who.range(of: " <") else { return who }
        return String(who[..<email.lowerBound])
    }
}
