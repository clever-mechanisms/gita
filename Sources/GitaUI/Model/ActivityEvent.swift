import Foundation

/// One line of the Activity window.
struct ActivityEvent {
    var date = Date()
    var title: String
    var detail: String
    var failed: Bool
}

/// A repository's recent activity, newest first, bounded so a long session does not grow it without end.
struct ActivityLog {
    static let capacity = 250
    private(set) var events: [ActivityEvent] = []

    mutating func record(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > Self.capacity { events.removeLast(events.count - Self.capacity) }
    }
}
