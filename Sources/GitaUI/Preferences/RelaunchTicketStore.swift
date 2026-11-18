import Foundation

/// The hand-over between an app restarting for a new language and its replacement: the predecessor's process and a
/// token passed on the replacement's command line, plus the repository requests that arrived while it restarted.
struct RelaunchTicket: Codable, Equatable {
    let token: UUID
    let predecessor: Int32
    let createdAt: Date
    var urls: [String] = []
}

/// Stores at most one `RelaunchTicket` in the settings domain. A ticket is only valid for a short window and only
/// while its stored copy matches, so a stale or foreign one never opens anything.
struct RelaunchTicketStore {
    static let key = "languageRelaunch.v1"
    static let argument = "--language-relaunch"
    private static let maximumSize = 32_768
    private static let maximumURLs = 32
    /// Seconds a ticket stays valid, allowing a little clock skew backwards.
    private static let validity: ClosedRange<TimeInterval> = -5...30

    let defaults: UserDefaults
    var urlScheme = AppEnvironment.defaultURLScheme
    var processIdentifier = ProcessInfo.processInfo.processIdentifier
    var now: @Sendable () -> Date = { Date() }

    func begin() -> RelaunchTicket? {
        let ticket = RelaunchTicket(token: UUID(), predecessor: processIdentifier, createdAt: now())
        guard let data = try? JSONEncoder().encode(ticket) else { return nil }
        defaults.set(data, forKey: Self.key)
        guard defaults.synchronize() else {
            cancel(ticket)
            return nil
        }
        return ticket
    }

    func isPending(_ ticket: RelaunchTicket) -> Bool {
        let elapsed = now().timeIntervalSince(ticket.createdAt)
        guard ticket.predecessor > 0, elapsed.isFinite, Self.validity.contains(elapsed), let stored = stored() else {
            return false
        }
        return stored.token == ticket.token && stored.predecessor == ticket.predecessor
            && stored.createdAt == ticket.createdAt
    }

    /// The ticket a replacement launched with `--language-relaunch TOKEN` takes over, if it is still pending.
    func pending(arguments: [String]) -> RelaunchTicket? {
        guard let index = arguments.firstIndex(of: Self.argument), arguments.indices.contains(index + 1),
            let token = UUID(uuidString: arguments[index + 1]), let ticket = stored(), ticket.token == token,
            ticket.predecessor != processIdentifier, isPending(ticket)
        else { return nil }
        return ticket
    }

    func cancel(_ ticket: RelaunchTicket) {
        guard stored()?.token == ticket.token else { return }
        defaults.removeObject(forKey: Self.key)
        _ = defaults.synchronize()
    }

    /// Adds repository and `gita://` requests for the replacement; false when they could not be kept.
    func queue(_ urls: [URL], for ticket: RelaunchTicket) -> Bool {
        guard isPending(ticket), var stored = stored() else { return false }
        for value in urls.filter(isForwardable).map(\.absoluteString) where !stored.urls.contains(value) {
            stored.urls.append(value)
        }
        guard stored.urls.count <= Self.maximumURLs, let updated = try? JSONEncoder().encode(stored),
            updated.count <= Self.maximumSize
        else { return false }
        defaults.set(updated, forKey: Self.key)
        return defaults.synchronize()
    }

    /// The ticket is no longer valid, or its stored copy was tampered with.
    struct InvalidTicket: Error {}

    /// The queued requests, removing the ticket.
    func consume(_ ticket: RelaunchTicket) throws(InvalidTicket) -> [URL] {
        guard isPending(ticket), let stored = stored(), stored.urls.count <= Self.maximumURLs else {
            throw InvalidTicket()
        }
        let urls = stored.urls.compactMap(URL.init(string:)).filter(isForwardable)
        guard urls.count == stored.urls.count else { throw InvalidTicket() }
        cancel(ticket)
        return urls
    }

    private func isForwardable(_ url: URL) -> Bool { url.isFileURL || url.scheme == urlScheme }

    private func stored() -> RelaunchTicket? {
        guard let data = defaults.data(forKey: Self.key), data.count <= Self.maximumSize else { return nil }
        return try? JSONDecoder().decode(RelaunchTicket.self, from: data)
    }
}
