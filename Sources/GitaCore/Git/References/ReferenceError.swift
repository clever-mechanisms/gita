import Foundation

/// A branch or tag's configuration or ancestry could not be established, or a tag request is invalid.
enum ReferenceError: Error, LocalizedError, Sendable {
    case mergeAncestryUnknown
    case configurationUnreadable
    case fetchMappingUnreadable
    case invalidFetchMapping
    case upstreamMissing
    case noFetchMapping
    case tagMessage

    var errorDescription: String? {
        switch self {
        case .mergeAncestryUnknown: String(localized: "Git could not establish this branch's merge ancestry.")
        case .configurationUnreadable: String(localized: "Git could not read the reference's configuration.")
        case .fetchMappingUnreadable: String(localized: "Git could not read the upstream's fetch mapping.")
        case .invalidFetchMapping: String(localized: "Git returned an invalid fetch mapping.")
        case .upstreamMissing:
            String(localized: "This branch's configured upstream is missing. Update or unset its upstream first.")
        case .noFetchMapping: String(localized: "This remote branch has no matching fetch mapping.")
        case .tagMessage: String(localized: "Enter a nonempty tag message of at most 64 KB.")
        }
    }
}
