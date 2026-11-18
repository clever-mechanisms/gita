/// The model's one read of the repository in flight, with its task: a refresh of the snapshot or a page of older
/// history (a search and a branch focus read on their own). Cancelling the reads returns it to `idle`, so a stopped or
/// reopened model never stays "loading". A refresh asked for meanwhile (`AppModel.pendingRefresh`) runs when the read
/// ends, however it ends.
enum RepositoryRead {
    case idle
    case refreshing(Task<Void, Never>)
    case loadingPage(Task<Void, Never>)

    var isActive: Bool {
        if case .idle = self { false } else { true }
    }

    var isRefreshing: Bool {
        if case .refreshing = self { true } else { false }
    }

    var task: Task<Void, Never>? {
        switch self {
        case .idle: nil
        case .refreshing(let task), .loadingPage(let task): task
        }
    }
}
