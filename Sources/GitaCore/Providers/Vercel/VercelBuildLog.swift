import Foundation

/// Failed-build output for one deployment: redacted, bounded, in memory for display only.
public struct VercelBuildLog: Sendable, Hashable {
    public var lines: [String]
    public var status: ProviderStatus
    public var diagnostic: String?

    public init(lines: [String], status: ProviderStatus, diagnostic: String? = nil) {
        self.lines = lines
        self.status = status
        self.diagnostic = diagnostic
    }

    init(failure: ProviderFailure) {
        self.init(lines: [], status: failure.status, diagnostic: failure.diagnostic)
    }

    // MARK: Parsing

    private static let outputTypes: Set<String> = ["stdout", "stderr", "command", "fatal"]
    private static let eventLimit = 200
    private static let lineLength = 300

    /// The last `limit` non-blank output lines in order, ANSI escapes stripped and secrets redacted. Events arrive
    /// newest first (`direction=backward`).
    static func lines(_ data: Data, limit: Int = 20) throws -> [String] {
        let events = try JSONDecoder().decode([Event].self, from: data)
        var lines: [String] = []
        for event in events.prefix(eventLimit) where outputTypes.contains(event.type ?? "") {
            let text = LogRedactor.redact(LogRedactor.stripANSI(event.text ?? event.payload?.text ?? ""))
            for line in text.split(whereSeparator: \.isNewline).reversed()
            where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(String(line.prefix(lineLength)))
                if lines.count == limit { return lines.reversed() }
            }
        }
        return lines.reversed()
    }

    private struct Event: Decodable {
        struct Payload: Decodable { var text: String? }

        var type: String?
        var text: String?
        var payload: Payload?
    }
}
