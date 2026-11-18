import Foundation

/// One remote or branch-tracking configuration entry, with where it was defined.
struct RemoteConfigEntry {
    var key: String
    var value: String
    var scope: String
    var origin: String
    /// Defined in this repository's own config file, which is the only file the app edits.
    var local: Bool

    var variable: String { key.split(separator: ".").last.map(String.init) ?? "" }
    var remoteName: String? { subsection("remote.") }
    var branchName: String? { subsection("branch.") }

    private func subsection(_ prefix: String) -> String? {
        guard key.hasPrefix(prefix), let end = key.lastIndex(of: "."),
            end >= key.index(key.startIndex, offsetBy: prefix.count)
        else { return nil }
        return String(key[key.index(key.startIndex, offsetBy: prefix.count)..<end])
    }
}

/// The repository's remotes and every remote/tracking configuration entry, from all config scopes.
struct RemoteCatalog {
    static let remoteLimit = 128
    /// Only remote and branch-tracking keys: no credential helper, HTTP authorization or unrelated configuration.
    static let configPattern = #"^(remote\..*|branch\..*\.(remote|pushremote|merge))$"#

    var root: URL
    var directory: URL
    var entries: [RemoteConfigEntry]
    var names: [String]
    var canWriteLocal: Bool

    /// `git config --null --show-origin --show-scope --get-regexp`: scope, origin and "key\nvalue" per entry.
    static func entries(_ output: Data, root: URL, localConfig: URL) throws -> [RemoteConfigEntry] {
        let fields = output.split(separator: GitOutput.nul, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true, (fields.count - 1) % 3 == 0 else {
            throw RemoteError.invalidConfiguration
        }
        return try stride(from: 0, to: fields.count - 1, by: 3).map { index in
            guard let scope = String(data: Data(fields[index]), encoding: .utf8),
                let origin = String(data: Data(fields[index + 1]), encoding: .utf8),
                let separator = fields[index + 2].firstIndex(of: GitOutput.lineFeed),
                let key = String(data: Data(fields[index + 2][..<separator]), encoding: .utf8),
                let value = String(
                    data: Data(fields[index + 2][fields[index + 2].index(after: separator)...]), encoding: .utf8)
            else {
                throw RemoteError.notRepresentable
            }
            return RemoteConfigEntry(
                key: key, value: value, scope: scope, origin: origin,
                local: isLocalFile(scope: scope, origin: origin, root: root, localConfig: localConfig))
        }
    }

    private static func isLocalFile(scope: String, origin: String, root: URL, localConfig: URL) -> Bool {
        guard scope == "local", let path = origin.dropPrefix("file:") else { return false }
        return URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.path
            == localConfig.standardizedFileURL.path
    }

    func entries(ofRemote name: String) -> [RemoteConfigEntry] { entries.filter { $0.remoteName == name } }
}
