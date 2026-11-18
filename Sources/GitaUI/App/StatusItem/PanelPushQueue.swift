import Foundation

/// A Push requested from the menu bar panel for a repository that is not the active one yet: it runs once that
/// repository is active and its snapshot is in. It is dropped when the panel's choice ends elsewhere (its open failed,
/// or the user chose another repository), and after 30 seconds.
@MainActor
struct PanelPushQueue {
    static let lifetime: TimeInterval = 30

    enum Request: Equatable {
        case none
        /// The repository is being selected, or read in a background tab before the switch.
        case selecting(URL, at: Date)
        /// The active repository changed since: it must be this one once it settles.
        case selected(URL, at: Date)
    }

    private(set) var request = Request.none

    mutating func request(_ url: URL, at date: Date) { request = .selecting(url, at: date) }

    /// The active repository changed: the first change is the panel's choice taking over; a second one means the user
    /// moved on.
    mutating func activeRepositoryChanged() {
        switch request {
        case .none: break
        case .selecting(let url, let date): request = .selected(url, at: date)
        case .selected: request = .none
        }
    }

    /// Whether to push now, given the active repository's state; an expired, performed or abandoned request is
    /// dropped. Once the active repository changed for it, any other settled repository (or none: its open failed)
    /// abandons it. Before that change it only waits, since a repository opening in the current tab passes through
    /// "no repository, not loading" on its way in.
    mutating func shouldPush(activeRoot: URL?, isBusy: Bool, now: Date) -> Bool {
        let (url, requestedAt, wasSelected): (URL, Date, Bool)
        switch request {
        case .none: return false
        case .selecting(let asked, let at): (url, requestedAt, wasSelected) = (asked, at, false)
        case .selected(let asked, let at): (url, requestedAt, wasSelected) = (asked, at, true)
        }
        if now.timeIntervalSince(requestedAt) > Self.lifetime {
            request = .none
            return false
        }
        guard !isBusy else { return false }
        guard let activeRoot, ProviderActivity.key(activeRoot) == ProviderActivity.key(url) else {
            if wasSelected { request = .none }
            return false
        }
        request = .none
        return true
    }
}
