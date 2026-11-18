/// The history's zoom (View › Zoom In/Out/Actual Size, Settings › Git, the Setup Guide), in percent of the normal row
/// height: 80 to 160 percent in steps of 10, 100 being actual size.
enum HistoryZoom {
    static let range = 80...160
    static let step = 10
    static let actual = 100
    /// Every size Settings offers.
    static var all: [Int] { Array(stride(from: range.lowerBound, through: range.upperBound, by: step)) }

    /// A stored percentage within `range`; 0 (never stored) is the actual size.
    static func clamped(_ percent: Int) -> Int {
        percent == 0 ? actual : bounded(percent)
    }
    /// A percentage pinned to `range`, 0 included (the Setup Guide's draft, which is never "not stored").
    static func bounded(_ percent: Int) -> Int { min(range.upperBound, max(range.lowerBound, percent)) }
    /// A stored value outside the range reads as actual size.
    static func shown(_ stored: Int) -> Int { range.contains(stored) ? stored : actual }
    static func zoomedIn(_ percent: Int) -> Int { clamped(percent + step) }
    static func zoomedOut(_ percent: Int) -> Int { clamped(percent - step) }
    static func canZoomIn(_ percent: Int) -> Bool { percent < range.upperBound }
    static func canZoomOut(_ percent: Int) -> Bool { percent > range.lowerBound }
}
