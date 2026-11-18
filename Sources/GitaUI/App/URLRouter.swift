import Foundation

/// Where an opened URL leads, and the requests that wait while the app cannot take them (launching, the setup guide,
/// a language restart).
@MainActor
final class URLRouter {
    enum Route: Equatable {
        /// `gita://open/<page>` (or `gita://<page>`): the main window, on that page when it names one.
        case window(Section?)
        /// A folder: opened as a repository tab.
        case repository(URL)
        case ignored
    }

    let scheme: String
    private(set) var pending: [URL] = []

    init(scheme: String) { self.scheme = scheme }

    func route(_ url: URL) -> Route {
        if url.isFileURL { return .repository(url) }
        guard url.scheme == scheme else { return .ignored }
        let last = url.lastPathComponent
        // In `gita://pull-requests` the page is the host; `gita://open/history` names it in the path.
        let name = last.isEmpty || last == "/" ? url.host ?? "" : last
        return .window(Section(link: name))
    }

    func enqueue(_ urls: [URL]) { pending.append(contentsOf: urls) }

    /// The waiting requests, now handed on.
    func drain() -> [URL] {
        defer { pending.removeAll() }
        return pending
    }
}
