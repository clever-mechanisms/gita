import Foundation

@testable import GitaCore

/// The `GitHubRemote` a github.com remote is, without asking `ssh -G`; nil for anything else.
func gitHubRemote(_ remote: String?) -> GitHubRemote? {
    remote.flatMap(RemoteAddress.init).flatMap(GitHubRemote.init(address:))
}
