import Foundation

/// One row of the Activity window, read from a model's `ActivityEvent`.
struct ActivityEntry: Equatable {
    enum Source: String { case git, github, vercel, orca, app }
    var date: Date
    var source: Source
    var event: String
    var detail: String
    var failed: Bool

    var sourceTitle: String {
        switch source {
        case .git: "Git"
        case .github: "GitHub"
        case .vercel: "Vercel"
        case .orca: "Orca"
        case .app: "Gitā"
        }
    }
    var resultTitle: String { failed ? String(localized: "Failed") : String(localized: "Completed") }

    /// Provider events are titled "GitHub: …" (AppModel); app-shell events are a fixed set; the rest are Git
    /// operations.
    init(_ event: ActivityEvent) {
        date = event.date
        detail = event.detail
        failed = event.failed
        let providers: [(String, Source)] = [("GitHub", .github), ("Vercel", .vercel), ("Orca", .orca)]
        if let (name, source) = providers.first(where: { event.title.hasPrefix($0.0 + ":") }) {
            self.source = source
            self.event = String(event.title.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            return
        }
        let appEvents: Set<String> = [
            String(localized: "Window opened"), String(localized: "Window closed"),
            String(localized: "Opens at login"),
            String(localized: "Login approval required"), String(localized: "Open at Login disabled"),
            String(localized: "Login item unavailable"), String(localized: "Notifications unavailable"),
            String(localized: "Open result failed"),
        ]
        source = appEvents.contains(event.title) ? .app : .git
        self.event = event.title
    }

    /// The detail worth showing under the table: not the generic "Completed" every success carries.
    var extraDetail: String? {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == String(localized: "Completed") ? nil : trimmed
    }

    /// The query matches the event, source, result or detail.
    func matches(_ query: String) -> Bool {
        event.localizedStandardContains(query) || sourceTitle.localizedStandardContains(query)
            || resultTitle.localizedStandardContains(query) || detail.localizedStandardContains(query)
    }

    /// Outcomes only: raw CLI diagnostics may contain local paths, remote URLs or account names, so `detail` is never
    /// exported.
    static func sanitizedJSON(_ rows: [Self]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        let objects = rows.map {
            [
                "date": formatter.string(from: $0.date), "source": $0.source.rawValue, "event": $0.event,
                "result": $0.failed ? "failed" : "completed",
            ]
        }
        return try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
    }
}
