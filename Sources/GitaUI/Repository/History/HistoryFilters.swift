import Foundation
import GitaCore

/// Value state for the §6a History Filter Bar: scope, removable author pill (`◐` highlight vs `⏷` filter),
/// and removable search pill (`⏷ field: query`).
struct HistoryFilters: Equatable {
    enum AuthorMode: Equatable, Sendable {
        case highlight
        case filter

        var symbol: String { self == .highlight ? "circle.lefthalf.filled" : "line.3.horizontal.decrease" }

        var accessibilityDescription: String {
            switch self {
            case .highlight: String(localized: "Highlighting author, click to filter")
            case .filter: String(localized: "Filtering by author, click to highlight")
            }
        }
    }

    enum Scope: Equatable {
        case all
        case currentBranch(String?)
        case reference(GitReference)
        case custom(count: Int)

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .currentBranch(let name): name ?? String(localized: "HEAD")
            case .reference(let reference): reference.name
            case .custom(let count): String(localized: "\(count) branches")
            }
        }
    }

    struct AuthorFilter: Equatable {
        var author: CommitAuthor
        var mode: AuthorMode
    }

    struct SearchFilter: Equatable {
        var field: HistorySearchField
        var query: String
    }

    enum Pill: Equatable {
        case author(AuthorFilter)
        case search(SearchFilter)
    }

    var scope: Scope = .all
    var author: AuthorFilter?
    var search: SearchFilter?

    var pills: [Pill] {
        var result: [Pill] = []
        if let author { result.append(.author(author)) }
        if let search, !search.query.isEmpty { result.append(.search(search)) }
        return result
    }

    static func resolveScope(
        focused: GitReference?, filters: BranchFilters, references: [GitReference], branch: String?
    ) -> Scope {
        if let focused {
            if let branch, focused.kind == .branch, focused.name == branch {
                return .currentBranch(branch)
            }
            return .reference(focused)
        }
        let validNames = Set(references.map(\.fullName))
        let only = filters.only.filter { validNames.contains($0) }
        if only.count == 1, let ref = references.first(where: { $0.fullName == only[0] }) {
            if let branch, ref.kind == .branch, ref.name == branch {
                return .currentBranch(branch)
            }
            return .reference(ref)
        }
        if only.count > 1 { return .custom(count: only.count) }
        return .all
    }

    static func mergedAuthors(
        repoTop: [AuthorSummary], commits: [GitCommit], me: CommitAuthor?, limit: Int = 10
    ) -> [CommitAuthor] {
        var result: [CommitAuthor] = []
        var seen: Set<String> = []
        func appendIfNew(_ author: CommitAuthor) {
            let key =
                author.email.isEmpty ? "n:" + author.name : "e:" + author.email.lowercased()
            guard !author.name.isEmpty, seen.insert(key).inserted else { return }
            result.append(author)
        }
        if let me { appendIfNew(me) }
        for summary in repoTop {
            appendIfNew(CommitAuthor(name: summary.name, email: summary.email))
            if result.count >= limit { return result }
        }
        for commit in commits {
            appendIfNew(CommitAuthor(commit))
            if result.count >= limit { break }
        }
        return result
    }
}
