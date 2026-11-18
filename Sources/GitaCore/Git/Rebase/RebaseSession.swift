import CryptoKit
import Darwin
import Foundation

/// The manifest lives outside rebase-merge so Git can remove its own directory.
/// A marker inside rebase-merge binds it to that directory's inode/birth identity;
/// an orphan manifest is never adopted by a later Git operation.
struct RebaseSession: Sendable {
    static let limit = 1_024 * 1_024
    static let messageLimit = 64 * 1_024
    static let container = "gita-rebase"
    static let markerName = "gita-session"
    static let pendingName = "gita-rebase-pending"
    let manifest: RebaseManifest
    let digest: String

    var directory: URL { URL(fileURLWithPath: manifest.gitDirectory, isDirectory: true) }
    var approved: [RebaseInstruction] {
        manifest.steps.map { RebaseInstruction(action: $0.action, commitID: $0.commitID) }
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString == id }

    static func create(_ review: GitService.RebaseReview, steps: [GitRebaseStep]) throws -> Self {
        let (root, directory, plan) = (review.root, review.directory, review.plan)
        let originalIDs = plan.commits.map(\.id)
        try validateSteps(steps, originalIDs: originalIDs)
        // A crash before Git invokes its sequence editor can leave only this
        // pointer. It blocks continuation but is never adopted as an active run.
        // With no operation present, a new start may remove that owned orphan.
        if let orphan = try pending(directory: directory) { try orphan.cleanup() }
        let id = UUID().uuidString
        // Git >=2.45 supports a whole comment string. A unique prefix preserves
        // ordinary # headings in reword text while Git cleans its own scaffold.
        let prefix = "# gita-" + id + ":"
        guard steps.allSatisfy({ $0.message?.contains(prefix) != true }) else { throw RebasePlanError.planChanged }
        let manifest = RebaseManifest(
            version: 1, id: id, root: root.path,
            rootIdentity: try RebaseFiles.directoryIdentity(root), gitDirectory: directory.path,
            gitIdentity: try RebaseFiles.directoryIdentity(directory), baseID: plan.base.id, headID: plan.headID,
            headName: plan.branch.map { "refs/heads/" + $0 } ?? "detached HEAD",
            originalIDs: originalIDs, steps: steps, commentPrefix: prefix)
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= limit else {
            throw RebasePlanError.planTooLarge
        }
        let git = try RebaseFiles.openDirectory(directory)
        defer { close(git) }
        let container = try RebaseFiles.privateDirectory(parent: git, name: Self.container, create: true)
        defer { close(container) }
        let run = try RebaseFiles.privateDirectory(parent: container, name: id, create: true, exclusive: true)
        defer { close(run) }
        let digest = hash(data)
        do {
            try RebaseFiles.create(data, parent: run, name: "manifest.json")
            try RebaseFiles.create(
                JSONEncoder().encode(RebasePending(version: 1, id: id, manifestDigest: digest)), parent: git,
                name: pendingName)
        } catch {
            _ = unlinkat(run, "manifest.json", 0)
            _ = unlinkat(container, id, AT_REMOVEDIR)
            throw error
        }
        return Self(manifest: manifest, digest: digest)
    }

    static func load(directory: URL, id: String) throws -> Self {
        guard validID(id), directory.path.hasPrefix("/"), RebaseFiles.lexicalPath(directory) == directory.path else {
            throw RebasePlanError.planChanged
        }
        let git = try RebaseFiles.openDirectory(directory)
        defer { close(git) }
        let container = try RebaseFiles.privateDirectory(parent: git, name: Self.container)
        defer { close(container) }
        let run = try RebaseFiles.privateDirectory(parent: container, name: id)
        defer { close(run) }
        guard let data = try RebaseFiles.read(parent: run, name: "manifest.json", limit: limit, privateFile: true)
        else { throw RebasePlanError.planChanged }
        let manifest = try JSONDecoder().decode(RebaseManifest.self, from: data)
        guard manifest.version == 1, manifest.id == id, manifest.gitDirectory == directory.path,
            manifest.gitIdentity == (try RebaseFiles.directoryIdentity(directory)),
            manifest.root.hasPrefix("/"),
            manifest.rootIdentity == (try RebaseFiles.directoryIdentity(URL(fileURLWithPath: manifest.root))),
            GitParsers.isObjectID(manifest.baseID), GitParsers.isObjectID(manifest.headID),
            manifest.originalIDs.last == manifest.headID,
            manifest.headName == "detached HEAD" || manifest.headName.hasPrefix("refs/heads/"),
            manifest.commentPrefix == "# gita-" + id + ":"
        else { throw RebasePlanError.planChanged }
        try validateSteps(manifest.steps, originalIDs: manifest.originalIDs)
        return Self(manifest: manifest, digest: hash(data))
    }

    static func active(directory: URL) throws -> Self? {
        let git = try RebaseFiles.openDirectory(directory)
        defer { close(git) }
        guard let rebase = try RebaseFiles.optionalDirectory(parent: git, name: "rebase-merge") else { return nil }
        defer { close(rebase) }
        guard let data = try RebaseFiles.read(parent: rebase, name: markerName, limit: 4_096, privateFile: true) else {
            return nil
        }
        let marker = try JSONDecoder().decode(RebaseMarker.self, from: data)
        let session = try load(directory: directory, id: marker.id)
        try session.validateMarker(marker, rebase: rebase)
        try session.validateGitState(rebase: rebase)
        return session
    }

    static func pending(directory: URL) throws -> Self? {
        let git = try RebaseFiles.openDirectory(directory)
        defer { close(git) }
        guard let data = try RebaseFiles.read(parent: git, name: pendingName, limit: 4_096, privateFile: true) else {
            return nil
        }
        let pointer = try JSONDecoder().decode(RebasePending.self, from: data)
        let session = try load(directory: directory, id: pointer.id)
        guard pointer.version == 1, pointer.manifestDigest == session.digest else { throw RebasePlanError.planChanged }
        return session
    }

    static func validateSteps(_ steps: [GitRebaseStep], originalIDs: [String]) throws {
        guard !originalIDs.isEmpty, originalIDs.count <= 500, steps.count == originalIDs.count,
            originalIDs.allSatisfy(GitParsers.isObjectID), Set(originalIDs).count == originalIDs.count,
            Set(steps.map(\.commitID)) == Set(originalIDs)
        else { throw RebasePlanError.commitsNotOnce }
        var retained = false
        for step in steps {
            if step.action == .reword {
                guard let message = step.message, !message.contains("\0"), message.utf8.count <= messageLimit,
                    !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw RebasePlanError.rewordMessage
                }
            } else if step.message != nil {
                throw RebasePlanError.messageNotAllowed
            }
            if step.action == .squash || step.action == .fixup {
                guard retained else {
                    throw RebasePlanError.squashWithoutPredecessor
                }
            }
            if step.action != .drop { retained = true }
        }
    }

    func editors() throws -> GitEditorEnvironment {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(), executable.isFileURL,
            access(executable.path, X_OK) == 0
        else { throw RebaseEditorError.editorUnavailable }
        func command(_ mode: String) -> String {
            [executable.path, GitRebaseEditor.argument, mode, manifest.gitDirectory, manifest.id]
                .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        }
        return GitEditorEnvironment(editor: command("message"), sequenceEditor: command("sequence"))
    }

    func validateRemaining() throws {
        let git = try RebaseFiles.openDirectory(directory)
        defer { close(git) }
        let rebase = try RebaseFiles.requiredDirectory(parent: git, name: "rebase-merge")
        defer { close(rebase) }
        try validateOwnedState(rebase: rebase)
        _ = try progress(rebase: rebase)
    }

    private func validateGitState(rebase: Int32) throws {
        func value(_ name: String) throws -> String {
            guard let data = try RebaseFiles.read(parent: rebase, name: name, limit: 64 * 1_024),
                let text = String(data: data, encoding: .utf8)
            else { throw RebasePlanError.planChanged }
            return text.trimmingCharacters(in: .newlines)
        }
        let original = try value("orig-head")
        let onto = try value("onto")
        let name = try value("head-name")
        guard original == manifest.headID, onto == manifest.baseID, name == manifest.headName else {
            throw RebasePlanError.planChanged
        }
        let unsupported = ["gpg_sign_opt", "signoff", "update-refs", "autostash", "reschedule-failed-exec"]
        let present = try unsupported.contains {
            try RebaseFiles.read(parent: rebase, name: $0, limit: Self.limit) != nil
        }
        guard !present else { throw RebasePlanError.planChanged }
        if let options = try RebaseFiles.read(parent: rebase, name: "strategy_opts", limit: Self.limit),
            !options.isEmpty
        {
            throw RebasePlanError.planChanged
        }
        if let strategy = try RebaseFiles.read(parent: rebase, name: "strategy", limit: 128),
            String(data: strategy, encoding: .utf8)?.trimmingCharacters(in: .newlines) != "ort"
        {
            throw RebasePlanError.planChanged
        }
    }

    private func validateMarker(_ marker: RebaseMarker, rebase: Int32) throws {
        guard marker.version == 1, marker.id == manifest.id, marker.manifestDigest == digest,
            marker.rebaseIdentity == (try RebaseFiles.identity(rebase))
        else { throw RebasePlanError.planChanged }
    }

    private func validateOwnedState(rebase: Int32) throws {
        guard let data = try RebaseFiles.read(parent: rebase, name: Self.markerName, limit: 4_096, privateFile: true)
        else { throw RebasePlanError.planChanged }
        try validateMarker(JSONDecoder().decode(RebaseMarker.self, from: data), rebase: rebase)
        try validateGitState(rebase: rebase)
    }

    func installSequence(at target: URL) throws {
        guard target.path == directory.appendingPathComponent("rebase-merge/git-rebase-todo").path else {
            throw RebasePlanError.planChanged
        }
        let git = try RebaseFiles.openDirectory(directory)
        defer { close(git) }
        let rebase = try RebaseFiles.requiredDirectory(parent: git, name: "rebase-merge")
        defer { close(rebase) }
        try validateGitState(rebase: rebase)
        guard try RebaseFiles.read(parent: rebase, name: "done", limit: Self.limit) == nil,
            try RebaseFiles.read(parent: rebase, name: Self.markerName, limit: 4_096, privateFile: true) == nil,
            let source = try RebaseFiles.read(parent: rebase, name: "git-rebase-todo", limit: Self.limit)
        else { throw RebasePlanError.planChanged }
        let generated = try parse(source, abbreviations: true)
        guard generated.count == manifest.originalIDs.count else {
            throw RebasePlanError.differentRange
        }
        for (row, expected) in zip(generated, manifest.originalIDs) {
            guard row.action == .pick, expected.hasPrefix(row.commitID) else { throw RebasePlanError.planChanged }
        }
        let marker = RebaseMarker(
            version: 1, id: manifest.id, manifestDigest: digest,
            rebaseIdentity: try RebaseFiles.identity(rebase))
        try RebaseFiles.create(JSONEncoder().encode(marker), parent: rebase, name: Self.markerName)
        let todo = manifest.steps.map { $0.action.rawValue + " " + $0.commitID + "\n" }.joined()
        try RebaseFiles.replace(Data(todo.utf8), parent: rebase, name: "git-rebase-todo", limit: Self.limit)
        if let pending = try Self.pending(directory: directory), pending.digest == digest {
            guard unlinkat(git, Self.pendingName, 0) == 0 else { throw RebasePlanError.planChanged }
        }
    }

    func editMessage(at target: URL) throws {
        guard target.path == directory.appendingPathComponent("COMMIT_EDITMSG").path else {
            throw RebasePlanError.planChanged
        }
        let git = try RebaseFiles.openDirectory(directory)
        defer { close(git) }
        let rebase = try RebaseFiles.requiredDirectory(parent: git, name: "rebase-merge")
        defer { close(rebase) }
        try validateOwnedState(rebase: rebase)
        let done = try progress(rebase: rebase)
        guard let current = done.last else { throw RebasePlanError.planChanged }
        if let stopped = try RebaseFiles.read(parent: rebase, name: "stopped-sha", limit: 128) {
            guard String(data: stopped, encoding: .utf8)?.trimmingCharacters(in: .newlines) == current.commitID else {
                throw RebasePlanError.planChanged
            }
        }
        guard current.action == .reword else { return }
        guard let message = manifest.steps.first(where: { $0.commitID == current.commitID })?.message else {
            throw RebasePlanError.planChanged
        }
        try RebaseFiles.replace(Data(message.utf8), parent: git, name: "COMMIT_EDITMSG", limit: Self.limit)
    }

    /// Git appends the current row to done before it acts. If it reschedules a
    /// failed row, that same row can occur at both the done tail and todo head.
    private func progress(rebase: Int32) throws -> [RebaseInstruction] {
        let rawDone = try parse(RebaseFiles.read(parent: rebase, name: "done", limit: Self.limit) ?? Data())
        var done: [RebaseInstruction] = []
        for row in rawDone where done.last != row { done.append(row) }
        let todo = try parse(RebaseFiles.read(parent: rebase, name: "git-rebase-todo", limit: Self.limit) ?? Data())
        let combined = done + todo
        if combined == approved { return done }
        if let last = done.last, todo.first == last, Array(done.dropLast()) + todo == approved { return done }
        throw RebasePlanError.remainingPlanChanged
    }

    private func parse(_ data: Data, abbreviations: Bool = false) throws -> [RebaseInstruction] {
        guard data.count <= Self.limit, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw RebasePlanError.planChanged
        }
        var result: [RebaseInstruction] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(manifest.commentPrefix) { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, let action = GitRebaseAction(rawValue: String(fields[0])) else {
                throw RebasePlanError.planChanged
            }
            let oid = String(fields[1])
            if abbreviations {
                guard oid.count >= 7, oid.count <= 64,
                    oid.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                else { throw RebasePlanError.planChanged }
            } else if !GitParsers.isObjectID(oid) {
                throw RebasePlanError.planChanged
            }
            result.append(RebaseInstruction(action: action, commitID: oid))
            guard result.count <= 2_000 else { throw RebasePlanError.planChanged }
        }
        return result
    }

    func cleanup() throws {
        // Called only after Git has removed its operation directory. Never recurse
        // through paths or remove anything other than this exact owned manifest.
        let git = try RebaseFiles.openDirectory(directory)
        defer { close(git) }
        if let active = try RebaseFiles.optionalDirectory(parent: git, name: "rebase-merge") {
            close(active)
            return
        }
        let container = try RebaseFiles.privateDirectory(parent: git, name: Self.container)
        defer { close(container) }
        let run = try RebaseFiles.privateDirectory(parent: container, name: manifest.id)
        defer { close(run) }
        guard
            let bytes = try RebaseFiles.read(parent: run, name: "manifest.json", limit: Self.limit, privateFile: true),
            Self.hash(bytes) == digest
        else { throw RebasePlanError.planChanged }
        if let pending = try Self.pending(directory: directory), pending.digest == digest {
            guard unlinkat(git, Self.pendingName, 0) == 0 else { throw RebasePlanError.planChanged }
        }
        guard unlinkat(run, "manifest.json", 0) == 0, unlinkat(container, manifest.id, AT_REMOVEDIR) == 0 else {
            throw RebaseEditorError.sessionNotRemoved
        }
    }
}
