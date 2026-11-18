import Foundation

/// Command fragments shared by several Git features.
enum GitArguments {
    /// One commit record for `GitParsers.commits`: ID, parents, author name, email, time, decorations, subject.
    static let commitFormat = "%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s"
    /// `git log` in topological order with NUL-ended records and decorations; append `--format=…` and revisions.
    static let log = ["log", "--topo-order", "--decorate=short", "--no-show-signature", "-z"]
    static let logRecord = log + ["--format=" + commitFormat]
    /// Diffs never run external diff drivers or text conversion filters, and are colour-free.
    static let safeDiff = ["--no-ext-diff", "--no-textconv", "--no-color"]
    /// Every reference with its object, HEAD marker, peeled object, and the types of both (the snapshot's reference
    /// list and identity, and the tips a history walk starts from).
    static let referenceList = [
        "for-each-ref",
        "--format=%(refname)%00%(objectname)%00%(HEAD)%00%(*objectname)%00%(objecttype)%00%(*objecttype)%00",
    ]
    /// Replacement refs change what an object ID means; reviews bind to their exact listing.
    static let replacementList = [
        "for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)%00", "--", "refs/replace/",
    ]
    /// Tracked-file status only, for cleanliness checks.
    static let trackedStatus = ["status", "--porcelain=v2", "-z", "--untracked-files=no"]
    /// Transports for clone and fetch: HTTPS, SSH and local paths only. An `insteadOf` rule must not turn an
    /// accepted URL into an executable helper.
    static let transportAllowList = [
        "-c", "protocol.allow=never", "-c", "protocol.file.allow=always", "-c", "protocol.https.allow=always",
        "-c", "protocol.ssh.allow=always", "-c", "protocol.ext.allow=never",
    ]
    static let noHooks = ["-c", "core.hooksPath=/dev/null"]
    /// Invocation-local settings for merge, rebase, cherry-pick and revert: no editor, no autostash or autosquash,
    /// no other refs rewritten. No repository or user configuration changes.
    static let operationOverrides = [
        "core.editor=true", "sequence.editor=true", "rebase.backend=merge", "rebase.autoStash=false",
        "rebase.autoSquash=false", "rebase.updateRefs=false", "merge.autoStash=false",
    ]

    /// Options before every command. Git stash internally uses pathspec magic to remove its saved untracked files,
    /// and an inherited `--literal-pathspecs` breaks that round trip; stash takes no user paths here, so every
    /// path-taking command stays literal.
    static func globalOptions(for arguments: [String], mutation: Bool) -> [String] {
        ["--no-pager"] + (arguments.first == "stash" ? [] : ["--literal-pathspecs"])
            + ["-c", "color.ui=false", "-c", "core.quotepath=false"] + (mutation ? [] : ["--no-optional-locks"])
    }

    static func configOptions(_ settings: [String]) -> [String] { settings.flatMap { ["-c", $0] } }
}
