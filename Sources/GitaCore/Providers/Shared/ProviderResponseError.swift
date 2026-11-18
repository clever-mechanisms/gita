import Foundation

/// A provider response that decoded but does not have the shape or identity the request asked for.
enum ProviderResponseError: Error, Sendable {
    case shape
}
