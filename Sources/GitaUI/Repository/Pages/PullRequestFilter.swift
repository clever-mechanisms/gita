import Foundation
import GitaCore

/// Which pull requests the Pull Requests page shows by lifecycle or review state.
enum PullRequestStateFilter: String, CaseIterable, Sendable {
    case all, open, reviewRequested, draft, merged, closed

    var localizedTitle: String {
        switch self {
        case .all: String(localized: "All")
        case .open: PullRequestLifecycle.open.localizedTitle
        case .reviewRequested: String(localized: "Review requested")
        case .draft: String(localized: "Draft")
        case .merged: PullRequestLifecycle.merged.localizedTitle
        case .closed: PullRequestLifecycle.closed.localizedTitle
        }
    }

    /// Secondary filters stay out of the way until a pull request matches them (or the user picked them).
    var hidesWhenEmpty: Bool {
        self == .reviewRequested || self == .draft
    }

    func matches(_ pr: PullRequestSummary) -> Bool {
        switch self {
        case .all: true
        case .open: pr.lifecycle == .open
        case .reviewRequested: pr.lifecycle == .open && !pr.isDraft && pr.reviewRequestedFromViewer
        case .draft: pr.lifecycle == .open && pr.isDraft
        case .merged: pr.lifecycle == .merged
        case .closed: pr.lifecycle == .closed
        }
    }
}

/// How pull requests are ordered on the Pull Requests page.
enum PullRequestSort: String, CaseIterable, Sendable {
    case status, updated, newest, oldest

    var localizedTitle: String {
        switch self {
        case .status: String(localized: "Open first")
        case .updated: String(localized: "Recently updated")
        case .newest: String(localized: "Newest")
        case .oldest: String(localized: "Oldest")
        }
    }
}

/// Pure filtering, sorting, counting and section grouping for the Pull Requests page.
struct PullRequestFilter: Equatable, Sendable {
    enum GroupKind: Equatable, Sendable {
        case open, merged, closed

        var localizedTitle: String {
            switch self {
            case .open: PullRequestLifecycle.open.localizedTitle
            case .merged: PullRequestLifecycle.merged.localizedTitle
            case .closed: PullRequestLifecycle.closed.localizedTitle
            }
        }
    }

    struct Group: Equatable, Sendable {
        var kind: GroupKind?
        var items: [ProviderItem]
    }

    struct AuthorCount: Equatable, Sendable {
        var login: String
        var count: Int
    }

    struct Presentation: Equatable, Sendable {
        var groups: [Group]
        var items: [ProviderItem]
        var counts: [PullRequestStateFilter: Int]
        var authors: [AuthorCount]
        var emptyMessage: String?
    }

    var state: PullRequestStateFilter = .all
    var author: String?
    var query = ""
    var sort: PullRequestSort = .status

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isActive: Bool { state != .all || author != nil || !trimmedQuery.isEmpty }

    func apply(to items: [ProviderItem]) -> Presentation {
        let counts = Self.counts(in: items)
        let authors = Self.authors(in: items)
        let filtered = items.filter(matches).sorted(by: comesBefore)
        let groups = Self.grouped(filtered, state: state, sort: sort)
        let empty = items.isEmpty || !filtered.isEmpty ? nil : emptyMessage()
        return Presentation(groups: groups, items: filtered, counts: counts, authors: authors, emptyMessage: empty)
    }

    private func matches(_ item: ProviderItem) -> Bool {
        guard let pr = item.pullRequest else { return state == .all && author == nil && trimmedQuery.isEmpty }
        guard state.matches(pr) else { return false }
        if let author {
            guard pr.author?.caseInsensitiveCompare(author) == .orderedSame else { return false }
        }
        let needle = trimmedQuery
        guard !needle.isEmpty else { return true }
        let fields = [item.title, "#\(pr.number)", item.branch ?? "", pr.author ?? "", pr.lifecycle.localizedTitle]
        return fields.contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func comesBefore(_ lhs: ProviderItem, _ rhs: ProviderItem) -> Bool {
        switch sort {
        case .status:
            let leftRank = Self.statusRank(lhs.pullRequest)
            let rightRank = Self.statusRank(rhs.pullRequest)
            if leftRank != rightRank { return leftRank < rightRank }
            return Self.newerUpdated(lhs, rhs)
        case .updated:
            return Self.newerUpdated(lhs, rhs)
        case .newest:
            return Self.compareCreated(lhs, rhs, descending: true)
        case .oldest:
            return Self.compareCreated(lhs, rhs, descending: false)
        }
    }

    private static func statusRank(_ pr: PullRequestSummary?) -> Int {
        guard let pr else { return 5 }
        switch pr.lifecycle {
        case .open:
            if pr.isDraft { return 2 }
            return pr.reviewRequestedFromViewer ? 0 : 1
        case .merged: return 3
        case .closed: return 4
        case .unknown: return 5
        }
    }

    private static func newerUpdated(_ lhs: ProviderItem, _ rhs: ProviderItem) -> Bool {
        let leftDate = lhs.date ?? .distantPast
        let rightDate = rhs.date ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return (lhs.pullRequest?.number ?? 0) > (rhs.pullRequest?.number ?? 0)
    }

    private static func compareCreated(_ lhs: ProviderItem, _ rhs: ProviderItem, descending: Bool) -> Bool {
        let fallback: Date = descending ? .distantPast : .distantFuture
        let leftDate = lhs.pullRequest?.createdAt ?? lhs.date ?? fallback
        let rightDate = rhs.pullRequest?.createdAt ?? rhs.date ?? fallback
        if leftDate != rightDate { return descending ? leftDate > rightDate : leftDate < rightDate }
        let leftNumber = lhs.pullRequest?.number ?? 0
        let rightNumber = rhs.pullRequest?.number ?? 0
        return descending ? leftNumber > rightNumber : leftNumber < rightNumber
    }

    private static func grouped(
        _ items: [ProviderItem], state: PullRequestStateFilter, sort: PullRequestSort
    ) -> [Group] {
        guard !items.isEmpty else { return [] }
        guard state == .all, sort == .status else { return [Group(kind: nil, items: items)] }
        let open = items.filter { $0.pullRequest?.lifecycle == .open }
        let merged = items.filter { $0.pullRequest?.lifecycle == .merged }
        let closed = items.filter {
            let lifecycle = $0.pullRequest?.lifecycle
            return lifecycle != .open && lifecycle != .merged
        }
        return [
            Group(kind: .open, items: open),
            Group(kind: .merged, items: merged),
            Group(kind: .closed, items: closed),
        ].filter { !$0.items.isEmpty }
    }

    private static func counts(in items: [ProviderItem]) -> [PullRequestStateFilter: Int] {
        var result: [PullRequestStateFilter: Int] = [:]
        for choice in PullRequestStateFilter.allCases {
            result[choice] =
                choice == .all
                ? items.count
                : items.filter { $0.pullRequest.map(choice.matches) ?? false }.count
        }
        return result
    }

    private static func authors(in items: [ProviderItem]) -> [AuthorCount] {
        var totals: [String: (login: String, count: Int)] = [:]
        for item in items {
            guard let login = item.pullRequest?.author, !login.isEmpty else { continue }
            let key = login.lowercased()
            let existing = totals[key]
            totals[key] = (existing?.login ?? login, (existing?.count ?? 0) + 1)
        }
        return totals.values
            .map { AuthorCount(login: $0.login, count: $0.count) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.login.localizedCaseInsensitiveCompare(rhs.login) == .orderedAscending
            }
    }

    private func emptyMessage() -> String {
        guard author == nil, trimmedQuery.isEmpty else {
            return String(localized: "No matching pull requests")
        }
        switch state {
        case .all: return String(localized: "No pull requests")
        case .open: return String(localized: "No open pull requests")
        case .reviewRequested: return String(localized: "No pull requests requesting your review")
        case .draft: return String(localized: "No draft pull requests")
        case .merged: return String(localized: "No merged pull requests")
        case .closed: return String(localized: "No closed pull requests")
        }
    }
}
