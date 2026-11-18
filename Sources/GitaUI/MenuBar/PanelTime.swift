import Foundation

/// "now", "44m", "15h 34m", "3d 2h": how long a row's agent has been in its state, or how old a feed event is.
@MainActor
enum PanelTime {
    private struct Style: Hashable {
        let units: Int
        let days: Bool
    }
    private static var formatters: [Style: DateComponentsFormatter] = [:]

    static func duration(since date: Date, now: Date, units: Int = 2) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        return formatter(Style(units: units, days: seconds >= 86_400)).string(from: seconds) ?? ""
    }

    private static func formatter(_ style: Style) -> DateComponentsFormatter {
        if let formatter = formatters[style] { return formatter }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = style.units
        formatter.allowedUnits = style.days ? [.day, .hour] : [.hour, .minute]
        formatters[style] = formatter
        return formatter
    }
}
