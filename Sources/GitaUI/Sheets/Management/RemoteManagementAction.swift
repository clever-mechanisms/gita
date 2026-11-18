import GitaCore

/// A reviewed change to the repository's remotes.
enum RemoteManagementAction: Sendable {
    case add(name: String, url: String)
    case setURL(GitRemoteDetails, String)
    case rename(GitRemoteDetails, String)
    case remove(GitRemoteDetails)
    case fetch(GitRemoteDetails)
}
