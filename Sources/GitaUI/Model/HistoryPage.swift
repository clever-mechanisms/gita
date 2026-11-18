import GitaCore

/// History is read in pages of `size` commits; each read asks for one more to learn whether another page follows.
enum HistoryPage {
    static let size = 500
    static var request: Int { size + 1 }
    /// The history read as the list scrolls on: a read costs Git about as much for 2 000 commits as for 500 (Linux:
    /// 47 ms against 31 ms, most of it fixed), so further pages are larger and the list reads four times less often.
    static let further = 2_000

    /// A further page appended to `existing`: only commits not already listed (`known` maps their IDs to rows).
    static func added(_ page: [GitCommit], known: [String: Int], size: Int = size) -> [GitCommit] {
        page.prefix(size).filter { known[$0.id] == nil }
    }
    static func hasMore(_ page: [GitCommit], size: Int = size) -> Bool { page.count > size }

    /// Row by commit ID for `commits`, keeping the first row of a repeated ID.
    static func rows(_ commits: [GitCommit]) -> [String: Int] {
        Dictionary(commits.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether a refresh can keep the pages loaded beyond the first: the same HEAD and validated references, and
    /// the same first page.
    static func keepsLoadedPages(_ old: RepositorySnapshot, _ next: RepositorySnapshot) -> Bool {
        old.commits.count > size && old.head == next.head && old.historyIdentity != nil
            && old.historyIdentity == next.historyIdentity && old.commits.prefix(size).elementsEqual(next.commits)
    }
}
