import Foundation

/// Non-modal inline banner shown at the top of the repository content area (`ContentBannerView`).
enum ContentBanner: Equatable {
    struct RetryAction: Equatable {
        let id: UUID
        let title: String
        let perform: @MainActor () -> Void

        init(
            id: UUID = UUID(), title: String = String(localized: "Retry"),
            perform: @escaping @MainActor () -> Void
        ) {
            self.id = id
            self.title = title
            self.perform = perform
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title
        }
    }

    case none
    case info(String)
    case failure(title: String, message: String, retry: RetryAction?)

    var isHidden: Bool { self == .none }

    var isFailure: Bool {
        if case .failure = self { true } else { false }
    }

    var retryAction: RetryAction? {
        if case .failure(_, _, let retry) = self { retry } else { nil }
    }

    var displayText: String {
        switch self {
        case .none: return ""
        case .info(let text): return text
        case .failure(let title, let message, _):
            if title.isEmpty { return message }
            if message.isEmpty { return title }
            return "\(title): \(message)"
        }
    }
}
