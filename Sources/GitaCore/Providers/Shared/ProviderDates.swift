import Foundation

/// Dates in provider responses: ISO 8601 text (with or without fractional seconds) and Unix milliseconds.
enum ProviderDates {
    /// Parses internet date-times with or without fractional seconds.
    private static let style = Date.ISO8601FormatStyle()
    private static let millisecondsThreshold = 10_000_000_000.0

    /// GitHub reports "never" as year 1; that is no date.
    static func iso8601(_ text: String?) -> Date? {
        guard let text, !text.hasPrefix("0001-") else { return nil }
        return try? style.parse(text)
    }

    static func milliseconds(_ value: Double?) -> Date? {
        value.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }

    /// Positive, finite milliseconds only.
    static func positiveMilliseconds(_ value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return milliseconds(value)
    }

    /// Unix seconds or milliseconds, told apart by magnitude.
    static func unix(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > millisecondsThreshold ? value / 1_000 : value)
    }
}
