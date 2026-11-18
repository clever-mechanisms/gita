import Foundation

/// The first page of a provider list: its items, the reported total and whether more exist.
public struct ProviderPage<Element: Sendable>: Sendable {
    public var items: [Element]
    public var total: Int?
    public var hasMore: Bool

    public init(items: [Element], total: Int? = nil, hasMore: Bool = false) {
        self.items = items
        self.total = total
        self.hasMore = hasMore
    }
}
