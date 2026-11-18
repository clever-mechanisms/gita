import Darwin
import Foundation

/// Reading one remote's reviewed state: configuration, resolved URLs, tracking refs and their symbolic chains.
extension GitService {
    func remoteCatalog() async throws -> RemoteCatalog {
        let root = try await repositoryRoot()
        let common = try await managementCommand(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], outputLimit: 64 * 1_024)
        let directory = URL(fileURLWithPath: GitOutput.withoutTerminalLF(common.text)).resolvingSymlinksInPath()
        let config = directory.appendingPathComponent("config")
        var info = stat()
        let found = lstat(config.path, &info) == 0
        let writable = found ? info.st_mode & S_IFMT == S_IFREG : errno == ENOENT
        let output = try await managementCommand(
            ["config", "--null", "--show-origin", "--show-scope", "--get-regexp", RemoteCatalog.configPattern],
            outputLimit: 4 * 1_024 * 1_024, allowed: [0, 1])
        let entries = try RemoteCatalog.entries(output.stdout, root: root, localConfig: config)
        let listed = try await managementCommand(["remote"], outputLimit: 64 * 1_024)
        let names = GitOutput.withoutTerminalLF(listed.text).split(separator: "\n").map(String.init)
        guard names.count <= RemoteCatalog.remoteLimit else {
            throw RemoteError.tooManyRemotes
        }
        return RemoteCatalog(root: root, directory: directory, entries: entries, names: names, canWriteLocal: writable)
    }

    func remoteReview(_ name: String, catalog: RemoteCatalog) async throws -> RemoteReview {
        guard catalog.names.contains(name) else {
            throw RemoteError.noLongerConfigured
        }
        try await validateRemoteName(name)
        let selected = catalog.entries(ofRemote: name)
        let rawFetch = selected.filter { $0.variable == "url" }.map(\.value)
        let rawPush = selected.filter { $0.variable == "pushurl" }.map(\.value)
        async let fetch = remoteURLs(name, push: false, fallback: rawFetch)
        async let push = remoteURLs(name, push: true, fallback: rawPush)
        let references = try await managementCommand([
            "for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)%00", "--", "refs/remotes/" + name + "/",
        ])
        let symbolic = try await trackingSymbolicReview(name: name, selected: selected, references: references.stdout)
        let (fetchResult, pushResult) = try await (fetch, push)
        let restriction = RemoteRestriction(
            name: name, catalog: catalog, rawFetch: rawFetch, rawPush: rawPush,
            fetchURLs: fetchResult.urls, pushURLs: pushResult.urls,
            symbolicTrackingIsSafe: symbolic.safe)
        var identity = Fingerprint()
        identity.add("root", catalog.root.path)
        identity.add("common-directory", catalog.directory.path)
        identity.add("remote", name)
        for entry in selected + restriction.mappings {
            identity.add("config-key", entry.key)
            identity.add("config-value", entry.value)
            identity.add("scope", entry.scope)
            identity.add("origin", entry.origin)
        }
        identity.add("tracking-refs", references.stdout)
        identity.add("fetch-urls", fetchResult.output)
        identity.add("push-urls", pushResult.output)
        identity.add("symbolic-tracking", symbolic.identity)
        let message = restriction.message
        let details = GitRemoteDetails(
            name: name, fetchURLs: restriction.fetchURLs.map(RemoteURLPolicy.displayURL),
            pushURLs: restriction.pushURLs.map(RemoteURLPolicy.displayURL),
            editableURL: message == nil ? rawFetch.first : nil, mutationRestriction: message, identity: identity.hex)
        return RemoteReview(details: details, canFetch: restriction.canFetch)
    }

    /// The URLs Git resolves for a remote (`insteadOf` applied); `fallback` when Git reports none.
    private func remoteURLs(
        _ name: String, push: Bool, fallback: [String]
    ) async throws -> (urls: [String], output: Data) {
        let result = try await managementCommand(
            ["remote", "get-url"] + (push ? ["--push"] : []) + ["--all", "--", name], outputLimit: 256 * 1_024,
            allowed: [0, 2, 128])
        guard result.exitCode == 0 else { return (fallback, result.stdout) }
        let urls = GitOutput.withoutTerminalLF(result.text).split(separator: "\n", omittingEmptySubsequences: false)
        return (urls.map(String.init), result.stdout)
    }

    /// Every symbolic tracking ref of the remote, and every exact fetch destination, must resolve within the
    /// remote's own namespace to an existing ref (or, for an exact destination, to nothing yet).
    private func trackingSymbolicReview(
        name: String, selected: [RemoteConfigEntry], references: Data
    ) async throws -> (safe: Bool, identity: String) {
        var review = TrackingChainReview(remote: name)
        guard review.collect(references: references, fetch: selected) else { return (false, review.identity.hex) }
        guard !review.roots.isEmpty else { return (true, review.identity.hex) }
        let options = try await localObjectOptions()
        for root in review.roots.sorted() {
            guard try await follow(root, review: &review, options: options) else { return (false, review.identity.hex) }
        }
        return (true, review.identity.hex)
    }

    private func follow(_ root: String, review: inout TrackingChainReview, options: [String]) async throws -> Bool {
        var ref = root
        var visited = Set<String>()
        while true {
            try Task.checkCancellation()
            guard review.mayVisit(ref, visited: visited) else { return false }
            visited.insert(ref)
            review.identity.add("chain-ref", ref)
            let valid = try await chainCommand(["check-ref-format", ref], options: [])
            guard valid.exitCode == 0 else { return false }
            let symbolic = try await chainCommand(["symbolic-ref", "--quiet", "--no-recurse", ref], options: options)
            review.identity.add("symbolic-status", String(symbolic.exitCode))
            review.identity.add("symbolic-target", symbolic.stdout)
            if symbolic.exitCode == 0 {
                guard let target = GitOutput.line(symbolic.stdout) else { return false }
                ref = target
                continue
            }
            guard symbolic.exitCode == 1 else { return false }
            return try await terminalIsSafe(
                ref, root: root, firstStep: visited.count == 1, review: &review, options: options)
        }
    }

    private func terminalIsSafe(
        _ ref: String, root: String, firstStep: Bool, review: inout TrackingChainReview, options: [String]
    ) async throws -> Bool {
        let terminal = try await chainCommand(["show-ref", "--verify", "--hash", "--", ref], options: options)
        review.identity.add("terminal-status", String(terminal.exitCode))
        review.identity.add("terminal-oid", terminal.stdout)
        if terminal.exitCode == 0 { return GitParsers.isObjectID(GitOutput.withoutTerminalLF(terminal.text)) }
        // A new exact destination is allowed; an absent target reached
        // through a symbolic link, or a previously listed ref, is not.
        guard firstStep, review.exact.contains(root), !review.existing.contains(root) else { return false }
        let absent = try await chainCommand(["show-ref", "--verify", "--quiet", "--", ref], options: options)
        review.identity.add("absent-status", String(absent.exitCode))
        return absent.exitCode == 1
    }

    private func chainCommand(_ arguments: [String], options: [String]) async throws -> CommandResult {
        try await managementCommand(options + arguments, timeout: 5, outputLimit: 4_096, allowed: [0, 1, 128])
    }
}
