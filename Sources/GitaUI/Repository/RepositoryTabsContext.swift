import Foundation

/// What a repository view asks of the tabs around it: the repositories open in tabs (the sidebar lists them first
/// and keeps them in the list) and the checkouts whose tab is still opening (their rows spin).
@MainActor
protocol RepositoryTabsContext: AnyObject {
    var openRepositories: [URL] { get }
    var loadingCheckouts: Set<String> { get }
}

extension RepositoryTabsController: RepositoryTabsContext {}
