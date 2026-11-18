import Foundation

/// One line of a history row, between two lanes. Stored as 32-bit values: a wide history keeps a row's every open
/// lane on it, so a long list holds millions of these (Linux: about 140 per row).
public struct GraphEdge: Sendable, Hashable {
    private var fromLane: Int32
    private var toLane: Int32
    private var colorIndex: Int32
    public var from: Int {
        get { Int(fromLane) }
        set { fromLane = Self.clamped(newValue) }
    }
    public var to: Int {
        get { Int(toLane) }
        set { toLane = Self.clamped(newValue) }
    }
    public var color: Int {
        get { Int(colorIndex) }
        set { colorIndex = Self.clamped(newValue) }
    }
    public init(from: Int, to: Int, color: Int) {
        fromLane = Self.clamped(from)
        toLane = Self.clamped(to)
        colorIndex = Self.clamped(color)
    }
    private static func clamped(_ value: Int) -> Int32 { Int32(clamping: value) }
}
public struct GraphRow: Sendable, Hashable {
    public var lane: Int
    public var color: Int
    public var incoming: [GraphEdge]
    public var outgoing: [GraphEdge]
    public init(lane: Int, color: Int, incoming: [GraphEdge], outgoing: [GraphEdge]) {
        self.lane = lane
        self.color = color
        self.incoming = incoming
        self.outgoing = outgoing
    }
}
