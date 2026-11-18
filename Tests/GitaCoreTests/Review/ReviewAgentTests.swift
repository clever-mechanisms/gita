import Foundation
import Testing

@testable import GitaCore

/// A repository with a bare `origin` (both temporary): `main` pushed, a feature branch, and a clone that's behind.
private struct ReviewFixture {
    let container: URL, root: URL, origin: URL
    let service: GitService
    let runner = CommandRunner()

    init() async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("GitaReview-" + UUID().uuidString)
        root = container.appendingPathComponent("work tree")
        origin = container.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = GitService(root: root)
        try await git(["init", "--bare", "--initial-branch=main", origin.path], at: container)
        try await git(["init", "--initial-branch=main", "--template="])
        for (key, value) in [
            ("user.name", "Review Tests"), ("user.email", "review@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"),
        ] { try await git(["config", key, value]) }
        try await git(["remote", "add", "origin", origin.path])
        try write("a.txt", "one\n")
        try await commit("Base")
        try await git(["push", "-u", "origin", "main"])
        try await git(["remote", "set-head", "origin", "main"])
    }
    func remove() { try? FileManager.default.removeItem(at: container) }
    func write(_ path: String, _ value: String) throws {
        try Data(value.utf8).write(to: root.appendingPathComponent(path))
    }
    @discardableResult func git(_ arguments: [String], at directory: URL? = nil) async throws -> CommandResult {
        let result = try await runner.run(
            executable: "git", arguments: arguments, directory: directory ?? root, timeout: 20, outputLimit: 1 << 20)
        if result.exitCode != 0 { throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self)) }
        return result
    }
    @discardableResult func commit(_ message: String) async throws -> String {
        try await git(["add", "--all"])
        try await git(["commit", "-m", message])
        return try await git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    }
}

@Test func referenceBadgesFoldRemoteCopiesIntoTheLocalPill() {
    let remotes: Set<String> = ["origin/main", "origin/HEAD", "origin/test", "upstream/main", "origin/feature"]
    let badges = ReferenceBadge.group(
        ["HEAD -> main", "origin/main", "origin/HEAD", "upstream/main", "test", "origin/feature", "tag: v1.0"],
        remoteNames: remotes)
    #expect(
        badges == [
            ReferenceBadge(name: "main", kind: .head, remotes: ["origin", "upstream"]),
            ReferenceBadge(name: "test", kind: .branch),
            ReferenceBadge(name: "origin/feature", kind: .remote),
            ReferenceBadge(name: "v1.0", kind: .tag),
        ])
    #expect(
        badges.map(\.fullName) == [
            "refs/heads/main", "refs/heads/test", "refs/remotes/origin/feature", "refs/tags/v1.0",
        ])
    // A remote's HEAD alone (its default branch isn't decorated here) stays visible.
    #expect(
        ReferenceBadge.group(["origin/HEAD"], remoteNames: remotes) == [
            ReferenceBadge(name: "origin/HEAD", kind: .remote)
        ])
    #expect(ReferenceBadge.group(["HEAD"], remoteNames: []).first?.kind == .detachedHead)
}

@Test func reviewAgentsUseTheirPermissiveFlagsAndInteractivePrompt() {
    #expect(ReviewAgent.claude.arguments(prompt: "p") == ["--dangerously-skip-permissions", "p"])
    #expect(
        ReviewAgent.codex.arguments(prompt: "p") == [
            "--dangerously-bypass-approvals-and-sandbox", "-c", "check_for_update_on_startup=false", "p",
        ])
    #expect(ReviewAgent.cursor.arguments(prompt: "p") == ["--yolo", "--disable-auto-update", "p"])
    #expect(ReviewAgent.grok.arguments(prompt: "-p") == ["--permission-mode", "bypassPermissions", "--", "-p"])
    #expect(ReviewAgent.gemini.arguments(prompt: "p") == ["--yolo", "--prompt-interactive", "p"])
    #expect(ReviewAgent.copilot.arguments(prompt: "p") == ["--yolo", "-i", "p"])
    #expect(ReviewAgent.opencode.arguments(prompt: "p") == ["--prompt", "p"])
}

@Test func reviewAgentDetectionFindsExecutablesAndPicksTheSavedOneFirst() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitaAgents-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bin = directory.appendingPathComponent("bin")
    let other = directory.appendingPathComponent("other")
    for folder in [bin, other] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    for (folder, name, mode) in [(bin, "codex", 0o755), (bin, "cursor-agent", 0o644), (other, "claude", 0o755)] {
        let file = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }
    // a folder isn't a CLI
    try FileManager.default.createDirectory(at: bin.appendingPathComponent("gemini"), withIntermediateDirectories: true)
    let path = ReviewAgentDetector.searchPath(
        loginPATH: "\(bin.path):relative", processPATH: "\(other.path):\(bin.path)", home: directory.path)
    #expect(Array(path.prefix(2)) == [bin.path, other.path])
    let installed = ReviewAgentDetector.installed(in: [bin.path, other.path])
    #expect(Set(installed.keys) == [.codex, .claude])
    #expect(ReviewAgentDetector.pick("codex", installed: installed) == .codex)
    // not executable: first installed in order
    #expect(ReviewAgentDetector.pick("cursor", installed: installed) == .claude)
    #expect(ReviewAgentDetector.pick("", installed: [:]) == nil)
}

@Test func reviewLaunchScriptQuotesEverything() {
    let script = ReviewLaunchScript.make(
        agent: .claude, executable: URL(fileURLWithPath: "/Users/x/.local/bin/claude"),
        directory: URL(fileURLWithPath: "/tmp/it's here"), prompt: "Review `main`; don't $(rm -rf)",
        path: ["/a b", "/c"])
    #expect(
        script == """
            #!/bin/sh
            rm -f -- "$0"
            cd -- '/tmp/it'"'"'s here' || exit 1
            export PATH='/a b:/c'
            export DISABLE_AUTOUPDATER='1'
            clear
            exec '/Users/x/.local/bin/claude' '--dangerously-skip-permissions' 'Review `main`; don'"'"'t $(rm -rf)'

            """)
}

@Test func reviewScopesFollowTheBranchItsUpstreamAndTheDefaultBranch() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.remove() }
    // A feature branch two commits past origin/main: its own commits, read from git since it isn't checked out.
    try await fixture.git(["switch", "-c", "feature"])
    try fixture.write("b.txt", "two\nthree\n")
    try await fixture.commit("Add b")
    try fixture.write("a.txt", "one\nfour\n")
    try await fixture.commit("Edit a")
    try await fixture.git(["switch", "main"])
    let feature = try await fixture.service.reviewScope(reference: "refs/heads/feature")
    #expect(feature.kind == .branch(tip: "feature", base: "origin/main"))
    #expect(feature.commits == 2 && feature.files == 2 && feature.insertions == 3 && feature.deletions == 0)
    #expect(feature.checkout == nil && !feature.includesWorkingTree)
    #expect(
        feature.prompt(skill: .builtIn, skillFile: nil).contains("git diff origin/main...feature")
            && feature.prompt(skill: .builtIn, skillFile: nil).contains("git show feature:<path>"))
    #expect(feature.prompt(skill: .builtIn, skillFile: nil).contains("read-only review"))

    // main with an unpushed commit, checked out with an uncommitted edit.
    try fixture.write("c.txt", "c\n")
    let unpushed = try await fixture.commit("Unpushed")
    try fixture.write("a.txt", "dirty\n")
    let main = try await fixture.service.reviewScope(reference: "refs/heads/main")
    #expect(main.kind == .unpushed(branch: "main", upstream: "origin/main") && main.commits == 1)
    #expect(
        main.checkout?.resolvingSymlinksInPath() == fixture.root.resolvingSymlinksInPath() && main.includesWorkingTree)
    #expect(main.prompt(skill: .builtIn, skillFile: nil).contains("git diff HEAD"))

    // origin/main ahead of main (Fork's "main...origin/main"): the incoming commits.
    try await fixture.git(["checkout", "--", "a.txt"])
    try await fixture.git(["push", "origin", "main"])
    try await fixture.git(["reset", "--hard", "HEAD~1"])
    let incoming = try await fixture.service.reviewScope(reference: "refs/remotes/origin/main")
    #expect(incoming.kind == .incoming(branch: "main", upstream: "origin/main") && incoming.commits == 1)

    // In sync and nothing new: the tip commit.
    try await fixture.git(["merge", "--ff-only", "origin/main"])
    let tip = try await fixture.service.reviewScope(reference: "refs/heads/main")
    #expect(tip.kind == .commit(id: unpushed, subject: "Unpushed", isMerge: false) && tip.files == 1)
    let commit = try await fixture.service.reviewScope(commit: unpushed)
    #expect(commit.checkout != nil && commit.prompt(skill: .builtIn, skillFile: nil).contains("git show \(unpushed)"))
    await #expect(throws: GitError.self) { _ = try await fixture.service.reviewScope(reference: "--upload-pack=x") }
}

@Test func branchActionsCreateFromAStartPointAndPushABranchNotCheckedOut() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.remove() }
    let base = try await fixture.git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    try fixture.write("b.txt", "b\n")
    try await fixture.commit("Second")
    try await fixture.service.createBranch(name: "from-base", from: base)
    #expect(try await fixture.git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines) == base)
    #expect(try await fixture.git(["branch", "--show-current"]).text == "from-base\n")
    try fixture.write("c.txt", "c\n")
    let tip = try await fixture.commit("On from-base")
    try await fixture.git(["switch", "main"])
    // Not checked out, no upstream yet: pushed to origin under its own name and tracked from now on.
    try await fixture.service.push(GitPushRequest(branch: "from-base", remote: "origin", remoteBranch: "from-base"))
    #expect(
        try await fixture.git(["rev-parse", "refs/heads/from-base"], at: fixture.origin).text.trimmingCharacters(
            in: .newlines) == tip)
    #expect(try await fixture.git(["rev-parse", "--abbrev-ref", "from-base@{upstream}"]).text == "origin/from-base\n")
    await #expect(throws: GitError.self) {
        try await fixture.service.push(GitPushRequest(branch: "missing", remote: "origin", remoteBranch: "missing"))
    }
    await #expect(throws: GitError.self) { try await fixture.service.createBranch(name: "-x", from: base) }
}

@Test func reviewLaunchScriptRunsTheAgentInTheCheckoutWithThePromptIntact() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GitaLaunch-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let checkout = folder.appendingPathComponent("it's a checkout")
    let bin = folder.appendingPathComponent("bin")
    for directory in [checkout, bin] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    // A stand-in agent: records where it ran, its arguments (one per line) and its environment.
    let stub = bin.appendingPathComponent("claude")
    let record = folder.appendingPathComponent("record.txt")
    try Data(
        "#!/bin/sh\n{ pwd; printf '%s\\n' \"$@\"; echo \"$DISABLE_AUTOUPDATER\"; echo \"$PATH\"; } > '\(record.path)'\n"
            .utf8
    ).write(to: stub)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    let prompt = "Review `main`; don't $(touch pwned) \"now\""
    let script = folder.appendingPathComponent("review.command")
    try Data(
        ReviewLaunchScript.make(
            agent: .claude, executable: stub, directory: checkout, prompt: prompt, path: [bin.path, "/usr/bin", "/bin"]
        ).utf8
    ).write(to: script)
    let result = try await CommandRunner().run(
        executable: "/bin/sh", arguments: [script.path], directory: folder, timeout: 10, outputLimit: 1 << 16)
    #expect(result.exitCode == 0)
    let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    #expect(URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath() == checkout.resolvingSymlinksInPath())
    #expect(Array(lines[1...2]) == ["--dangerously-skip-permissions", prompt])
    #expect(lines[3] == "1" && lines[4] == "\(bin.path):/usr/bin:/bin")
    #expect(!FileManager.default.fileExists(atPath: script.path)) // one-shot: it deleted itself
    #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("pwned").path))
}

@Test func reviewSkillsAreBundledWithTheirLicensesAndAdaptedToTheRange() throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/ReviewSkills", isDirectory: true)
    #expect(ReviewSkill.default == .mattPocock)
    // Gitā's own skill keeps its saved value; its folder is `gita-review`, published in the Gitā repository.
    #expect(ReviewSkill.builtIn.file(in: folder).path.hasSuffix("ReviewSkills/gita-review/SKILL.md"))
    #expect(ReviewSkill.builtIn.sourceURL?.path.hasPrefix("/rolottr/gita/") == true)
    for skill in ReviewSkill.allCases {
        let file = skill.file(in: folder)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("---\nname: "), "\(skill) SKILL.md")
        #expect(
            FileManager.default.fileExists(
                atPath: file.deletingLastPathComponent().appendingPathComponent("LICENSE").path), "\(skill) LICENSE")
        #expect(skill.sourceURL?.host == "github.com")
    }
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("caveman-review/NOTICE").path))

    let scope = ReviewScope(
        kind: .branch(tip: "feature", base: "origin/main"), commits: 3, files: 4, insertions: 50, deletions: 2,
        checkout: nil, includesWorkingTree: false)
    let skillFile = URL(
        fileURLWithPath: "/Applications/Gita.app/Contents/Resources/ReviewSkills/mattpocock-code-review/SKILL.md")
    let matt = scope.prompt(skill: .mattPocock, skillFile: skillFile)
    #expect(matt.contains("Review it with the Matt Pocock Review skill: read `\(skillFile.path)` first and follow it."))
    #expect(
        matt.contains("fixed point is `origin/main` and the change is `feature`: use `git diff origin/main...feature`"))
    #expect(matt.contains("read-only review") && !matt.contains("Skip style nits"))
    let caveman = scope.prompt(skill: .caveman, skillFile: skillFile)
    #expect(caveman.contains("`<file>:L<line>`") && !caveman.contains("Spec axis"))
    let gita = scope.prompt(skill: .builtIn, skillFile: ReviewSkill.builtIn.file(in: folder))
    #expect(gita.contains("Review it with the Gitā Review skill: read `") && gita.contains("gita-review/SKILL.md"))
    #expect(gita.contains("read-only review") && !gita.contains("Skip style nits"))
    // Without the bundled file it's the plain Gita method.
    #expect(scope.prompt(skill: .thermoNuclear, skillFile: nil) == scope.prompt(skill: .builtIn, skillFile: nil))
    #expect(
        scope.prompt(skill: .builtIn, skillFile: nil).contains("Skip style nits")
            && scope.prompt(skill: .builtIn, skillFile: nil).contains("git show feature:<path>"))
    let merge = ReviewScope(
        kind: .commit(id: String(repeating: "a", count: 40), subject: "Merge x", isMerge: true), commits: 1, files: 1,
        insertions: 1, deletions: 0, checkout: URL(fileURLWithPath: "/r"), includesWorkingTree: false)
    #expect(
        merge.prompt(skill: .mattPocock, skillFile: skillFile).contains(
            "fixed point is `\(String(repeating: "a", count: 40))^1`"))
}
