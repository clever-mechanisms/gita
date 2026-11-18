/// The fixed repository statuses `AppModel.status` holds in English (views compare some of them); other statuses
/// ("Fetch…", "3 changed files") are already localized when set.
enum RepositoryStatusText: String {
    case openRepository = "Open a repository"
    case refreshing = "Refreshing…"
    case clean = "Working tree clean"
    case refreshFailed = "Refresh failed"
    case loadingHistory = "Loading history…"
    case historyLoaded = "History loaded"
    case historyFailed = "History failed"
    case searchFailed = "Search failed"
    case resolvingConflict = "Resolving conflict…"
    case rebasing = "Rebasing…"

    /// The status says a read failed.
    var isFailure: Bool { [.refreshFailed, .historyFailed, .searchFailed].contains(self) }

    var localizedTitle: String {
        switch self {
        case .openRepository: String(localized: "Open a repository")
        case .refreshing: String(localized: "Refreshing…")
        case .clean: String(localized: "Working tree clean")
        case .refreshFailed: String(localized: "Refresh failed")
        case .loadingHistory: String(localized: "Loading history…")
        case .historyLoaded: String(localized: "History loaded")
        case .historyFailed: String(localized: "History failed")
        case .searchFailed: String(localized: "Search failed")
        case .resolvingConflict: String(localized: "Resolving conflict…")
        case .rebasing: String(localized: "Rebasing…")
        }
    }
}
