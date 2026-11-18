import Foundation

/// Relative times and durations, localized by Foundation.
@MainActor
enum DeckFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        return formatter
    }()
    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()
    private static let secondsPerHour: TimeInterval = 3_600
    private static let secondsPerWeek: TimeInterval = 7 * 86_400
    /// Within this window around now a date reads "now" (a little more into the past than the future).
    private static let nowWindow: ClosedRange<TimeInterval> = -60...45
    private static let dayCacheLimit = 20_000
    private static var dayCache: [Date: String] = [:]

    /// "40 min ago" for the last week, then a date.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let age = now.timeIntervalSince(date)
        if age > nowWindow.lowerBound && age < nowWindow.upperBound { return String(localized: "now") }
        if age < secondsPerWeek { return relativeFormatter.localizedString(for: date, relativeTo: now) }
        // Older dates read the same whenever they are asked for (most history rows): format each once.
        if let cached = dayCache[date] { return cached }
        let value = dayFormatter.string(from: date)
        if dayCache.count > dayCacheLimit { dayCache.removeAll(keepingCapacity: true) }
        dayCache[date] = value
        return value
    }
    /// "3d 14h", "65s". From an hour on, whole minutes.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let rounded = seconds >= secondsPerHour ? (seconds / 60).rounded() * 60 : seconds.rounded()
        return durationFormatter.string(from: max(1, rounded)) ?? ""
    }
}
