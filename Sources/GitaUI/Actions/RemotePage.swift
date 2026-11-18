import Foundation
import GitaCore

/// A remote's web page. A remote that reaches github.com (SSH host aliases and `insteadOf` resolved by the snapshot or
/// `GitHubRemoteResolver`) opens its github.com page; any other remote keeps `RemoteWebPage`'s reading of its URL.
enum RemotePage {
    /// The checkout's repository page.
    static func repository(_ snapshot: RepositorySnapshot?) -> URL? {
        snapshot?.github?.webURL ?? RemoteWebPage.repository(snapshot?.remoteURL)
    }

    /// The page of a remote read outside a snapshot: another checkout's default remote, or a named remote.
    static func repository(remote: String?) async -> URL? {
        await GitHubRemoteResolver().resolve(remote)?.webURL ?? RemoteWebPage.repository(remote)
    }

    /// `branch` on the remote's host where the host has a branch page, else the repository page.
    static func branch(remote: String?, branch: String) async -> URL? {
        guard let page = await repository(remote: remote) else { return nil }
        return RemoteWebPage.branch(page.absoluteString, branch: branch) ?? page
    }
}
