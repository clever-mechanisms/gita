import Foundation

/// The value a missing or `null` response field stands for.
protocol DecodingDefault {
    associatedtype Value: Decodable & Sendable
    static var value: Value { get }
}

/// A response field that is absent or `null` decodes to its default instead of an optional; a value of the wrong
/// type still fails the decode.
@propertyWrapper
struct DecodedDefault<Default: DecodingDefault>: Decodable, Sendable {
    var wrappedValue: Default.Value

    init(wrappedValue: Default.Value = Default.value) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? Default.value : try container.decode(Default.Value.self)
    }
}

extension KeyedDecodingContainer {
    func decode<Default>(_ type: DecodedDefault<Default>.Type, forKey key: Key) throws -> DecodedDefault<Default> {
        try decodeIfPresent(type, forKey: key) ?? DecodedDefault()
    }
}

/// Missing means false.
enum DefaultFalse: DecodingDefault {
    static var value: Bool { false }
}

/// Missing means true.
enum DefaultTrue: DecodingDefault {
    static var value: Bool { true }
}

/// Missing means no elements.
enum DefaultEmpty<Element: Decodable & Sendable>: DecodingDefault {
    static var value: [Element] { [] }
}
