import Foundation

/// A parsed value and whether some of it was missing or cut off.
struct ProviderParsed<Value: Sendable>: Sendable {
    var value: Value
    var partial: Bool
}
