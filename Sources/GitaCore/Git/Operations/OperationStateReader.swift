import Foundation

/// Reads which Git operation (merge, rebase, cherry-pick, revert, am) is stopped in one `.git` directory, and an
/// identity over every metadata file the operation's next step depends on.
struct OperationStateReader {
    private static let rebaseMergeFiles = [
        "onto", "orig-head", "stopped-sha", "git-rebase-todo", "message", "message-squash", "current-fixups",
        "gpg_sign_opt", "signoff", "update-refs", "autostash", "reschedule-failed-exec", "strategy", "strategy_opts",
    ]
    private static let rebaseApplyFiles = ["onto", "orig-head", "original-commit", "abort-safety", "rebasing"]
    private static let sequencerFiles = ["head", "abort-safety", "todo", "opts"]

    private struct Probe {
        var kind: GitOperationKind
        var branch: String?
        var step: Int?
        var total: Int?
        var isEditingCommit = false
    }

    private let directory: URL
    private let head: String?
    /// Every metadata file read, with its identity, in reading order.
    private var collected = Fingerprint()

    private init(directory: URL, head: String?) {
        self.directory = directory
        self.head = head
    }

    static func read(directory: URL, head: String?) throws -> GitOperationState? {
        var reader = Self(directory: directory, head: head)
        guard var probe = try reader.probe() else { return nil }
        if probe.branch == nil, let raw = reader.string(try reader.read("HEAD")) {
            probe.branch = raw.dropPrefix("ref: refs/heads/")
        }
        var identity = Fingerprint()
        identity.add("kind", probe.kind.rawValue)
        identity.add("head", head ?? "unborn")
        identity.add("metadata", reader.collected.hex)
        return GitOperationState(
            kind: probe.kind, identity: identity.hex, branch: probe.branch,
            step: probe.step.flatMap { $0 > 0 ? $0 : nil }, total: probe.total.flatMap { $0 > 0 ? $0 : nil },
            isEditingCommit: probe.isEditingCommit)
    }

    private mutating func probe() throws -> Probe? {
        if try directoryExists("rebase-merge") { return try rebaseMerge() }
        if try directoryExists("rebase-apply") { return try rebaseApply() }
        if try read("MERGE_HEAD") != nil {
            _ = try read("MERGE_MODE")
            _ = try read("ORIG_HEAD")
            return Probe(kind: .merge)
        }
        if try read("CHERRY_PICK_HEAD") != nil { return try pick(.cherryPick) }
        if try read("REVERT_HEAD") != nil { return try pick(.revert) }
        if try directoryExists("sequencer") { return try sequencerOnly() }
        return nil
    }

    private mutating func rebaseMerge() throws -> Probe {
        try readSessionManifest(pointer: RebaseSession.pendingName, as: RebasePending.self)
        var probe = Probe(
            kind: .rebase, branch: branchName(try read("rebase-merge/head-name")),
            step: string(try read("rebase-merge/msgnum")).flatMap(Int.init),
            total: string(try read("rebase-merge/end")).flatMap(Int.init))
        for name in Self.rebaseMergeFiles { _ = try read("rebase-merge/" + name) }
        let done = string(try read("rebase-merge/done"))
        let amend = string(try read("rebase-merge/amend"))
        probe.isEditingCommit = Self.isEditingCommit(done: done, amend: amend, head: head)
        try readSessionManifest(pointer: "rebase-merge/" + RebaseSession.markerName, as: RebaseMarker.self)
        return probe
    }

    /// Git amends the stopped commit only when HEAD is still that commit and the last done row is `edit`.
    static func isEditingCommit(done: String?, amend: String?, head: String?) -> Bool {
        guard let amend, GitParsers.isObjectID(amend), amend == head,
            let last = done?.split(separator: "\n").last(where: { !$0.isEmpty && !$0.hasPrefix("#") })
        else { return false }
        return last.split(whereSeparator: { $0 == " " || $0 == "\t" }).first == "edit"
    }

    /// A native interactive rebase's manifest belongs to the operation's identity too.
    private mutating func readSessionManifest<Pointer: Decodable & RebaseSessionPointer>(
        pointer: String, as type: Pointer.Type
    ) throws {
        guard let data = try read(pointer), let decoded = try? JSONDecoder().decode(type, from: data),
            RebaseSession.validID(decoded.id)
        else { return }
        _ = try read(RebaseSession.container + "/" + decoded.id + "/manifest.json")
    }

    private mutating func rebaseApply() throws -> Probe {
        let kind: GitOperationKind = try read("rebase-apply/applying") != nil ? .apply : .rebase
        let probe = Probe(
            kind: kind, branch: branchName(try read("rebase-apply/head-name")),
            step: string(try read("rebase-apply/next")).flatMap(Int.init),
            total: string(try read("rebase-apply/last")).flatMap(Int.init))
        for name in Self.rebaseApplyFiles { _ = try read("rebase-apply/" + name) }
        return probe
    }

    private mutating func pick(_ kind: GitOperationKind) throws -> Probe {
        if try directoryExists("sequencer") {
            for name in Self.sequencerFiles { _ = try read("sequencer/" + name) }
        }
        return Probe(kind: kind)
    }

    /// A multi-commit pick or revert between steps: only the sequencer says which.
    private mutating func sequencerOnly() throws -> Probe {
        guard let todo = string(try read("sequencer/todo")) else {
            throw OperationError.incompleteSequence
        }
        let command = todo.split(separator: "\n").first { !$0.hasPrefix("#") && !$0.isEmpty }?.split(separator: " ")
            .first
        let kind: GitOperationKind
        switch command {
        case "pick": kind = .cherryPick
        case "revert": kind = .revert
        default:
            throw OperationError.unsupportedSequence
        }
        for name in Self.sequencerFiles where name != "todo" { _ = try read("sequencer/" + name) }
        return Probe(kind: kind)
    }

    private mutating func read(_ path: String) throws -> Data? {
        guard let file = try BoundedFile.read(directory.appendingPathComponent(path)) else { return nil }
        collected.add(path + "\0" + file.identity, file.data)
        return file.data
    }

    private mutating func directoryExists(_ path: String) throws -> Bool {
        guard
            let info = try BoundedFile.directoryExists(
                directory.appendingPathComponent(path),
                failure: OperationError.stateUnreadable,
                notDirectory: OperationError.metadataNotDirectory)
        else { return false }
        collected.add(path + "\0" + FileIdentity.of(info, includeModification: false), Data())
        return true
    }

    private func string(_ data: Data?) -> String? {
        data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .newlines)
    }

    private func branchName(_ data: Data?) -> String? {
        string(data).map { $0.dropPrefix(GitReference.Kind.branch.prefix) ?? $0 }
    }
}
