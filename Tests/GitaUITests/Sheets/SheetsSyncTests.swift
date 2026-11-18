import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// The Fetch, Pull and Push sheets: what they offer first and what they answer with.
@MainActor
@Suite("Sync sheets")
struct SheetsSyncTests {
    private func reference(_ name: String, _ kind: GitReference.Kind, current: Bool = false) -> GitReference {
        let namespace = kind == .branch ? "refs/heads/" : "refs/remotes/"
        return GitReference(name: name, fullName: namespace + name, commit: "c", kind: kind, isCurrent: current)
    }

    private func choices(
        branch: String? = "feature", upstreams: [String: GitBranchUpstream] = [:]
    ) -> SyncChoices {
        var snapshot = RepositorySnapshot(
            root: URL(fileURLWithPath: "/tmp/repo"), branch: branch, head: "c", changes: [], commits: [],
            references: [
                reference("main", .branch), reference("feature", .branch, current: branch == "feature"),
                reference("origin/HEAD", .remote), reference("origin/main", .remote),
                reference("origin/feature", .remote), reference("team/a/main", .remote),
                reference("team/a/next", .remote),
            ],
            worktrees: [], stashes: [], remoteURL: nil, gitDirectory: URL(fileURLWithPath: "/tmp/repo/.git"))
        snapshot.remoteURLs = ["team/a": "x", "origin": "y", "backup": "z"]
        return SyncChoices(snapshot: snapshot, upstreams: upstreams)
    }

    @Test func choicesPutOriginAndTheCheckedOutBranchFirst() {
        let choices = choices()
        #expect(choices.remotes == ["origin", "backup", "team/a"])
        #expect(choices.branches == ["feature", "main"])
        #expect(choices.branches(on: "origin") == ["main", "feature"])
        #expect(choices.branches(on: "team/a") == ["main", "next"])
        #expect(choices.branches(on: "backup").isEmpty)
        #expect(choices.preferredRemote == "origin")
        #expect(choices.pullTarget == SyncTarget(remote: "origin", branch: "feature"))
    }

    @Test func theUpstreamComesFirstAsTheDefault() {
        let upstream = GitBranchUpstream(remote: "team/a", branch: "next")
        let choices = choices(upstreams: ["feature": upstream])
        #expect(choices.preferredRemote == "team/a")
        #expect(choices.pullTarget == SyncTarget(remote: "team/a", branch: "next", isDefault: true))
        let targets = choices.pushTargets(for: "feature")
        #expect(targets.first?.title == "default (team/a/next)")
        #expect(targets.count == 4)
        #expect(!targets.dropFirst().contains { $0.name == "team/a/next" })
        // Without an upstream: the same name on the preferred remote, new when not there yet.
        #expect(choices.pushTargets(for: "main").first == SyncTarget(remote: "team/a", branch: "main"))
        #expect(self.choices().pushTargets(for: "fresh").first?.title == "origin/fresh (new)")
    }

    @Test func fetchTakesAllRemotesUnlessOneIsChosen() {
        let sheet = FetchSheet(choices: choices())
        #expect(sheet.window.title == "Fetch")
        #expect(sheet.all.state == .on && !sheet.remote.isEnabled)
        #expect(sheet.choice == .some(nil))
        sheet.all.state = .off
        sheet.allChanged()
        #expect(sheet.remote.isEnabled)
        sheet.remote.selectItem(at: 1)
        #expect(sheet.choice == .some("backup"))
    }

    @Test func pullOffersTheChosenRemotesBranchesIntoTheCurrentOne() {
        let sheet = PullSheet(choices: choices(), into: "feature")
        #expect(sheet.remote.titleOfSelectedItem == "origin")
        #expect(sheet.branch.titleOfSelectedItem == "feature")
        sheet.mode.selectItem(at: GitPullMode.allCases.firstIndex(of: .rebase) ?? 0)
        #expect(sheet.choice == GitPullRequest(remote: "origin", branch: "feature", mode: .rebase))
        sheet.remote.selectItem(at: 2)
        sheet.remoteChanged()
        #expect(sheet.branch.itemTitles == ["main", "next"])
        #expect(sheet.branch.titleOfSelectedItem == "main")
        sheet.autostash.state = .on
        #expect(sheet.choice == GitPullRequest(remote: "team/a", branch: "main", mode: .rebase, autostash: true))
        // A remote never fetched has no branch: nothing to pull.
        sheet.remote.selectItem(at: 1)
        sheet.remoteChanged()
        #expect(sheet.choice == nil && !sheet.defaultButton.isEnabled)
    }

    @Test func pushSendsTheChosenBranchToTheChosenTarget() {
        let sheet = PushSheet(choices: choices(), branch: "main")
        #expect(sheet.branch.titleOfSelectedItem == "main")
        #expect(sheet.target.titleOfSelectedItem == "origin/main")
        sheet.branch.selectItem(at: 0)
        sheet.branchChanged()
        #expect(sheet.target.titleOfSelectedItem == "origin/feature")
        sheet.target.selectItem(at: sheet.target.itemTitles.firstIndex(of: "team/a/next") ?? 0)
        sheet.tags.state = .on
        sheet.force.state = .on
        sheet.forceChanged()
        #expect(sheet.defaultButton.hasDestructiveAction)
        #expect(
            sheet.choice
                == GitPushRequest(branch: "feature", remote: "team/a", remoteBranch: "next", tags: true, force: true))
    }

    @Test func aSheetAnswersOnlyThroughItsDefaultButton() {
        let alerts = AppRecordingAlerts()
        let window = NSWindow()
        let answers = AppBox<[String?]>([])
        FetchSheet(choices: choices()).present(on: window, alerts: alerts.presenter) { answers.value.append($0) }
        alerts.answer(.alertSecondButtonReturn)
        #expect(answers.value.isEmpty)
        FetchSheet(choices: choices()).present(on: window, alerts: alerts.presenter) { answers.value.append($0) }
        alerts.answer()
        #expect(answers.value == [nil])
    }

    @Test func theButtonsEndTheSheetWithTheirAnswer() async {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        defer { parent.close() }
        let answers = AppBox<[String?]>([])
        let cancelled = FetchSheet(choices: choices())
        cancelled.present(on: parent, alerts: .standard) { answers.value.append($0) }
        await appWaitUntil { parent.attachedSheet === cancelled.window }
        cancelled.cancel()
        await appWaitUntil { parent.attachedSheet == nil }
        let confirmed = FetchSheet(choices: choices())
        confirmed.present(on: parent, alerts: .standard) { answers.value.append($0) }
        await appWaitUntil { parent.attachedSheet === confirmed.window }
        #expect(confirmed.window.frame.width > SyncForm.controlWidth + 64)
        confirmed.confirm()
        await appWaitUntil { answers.value == [nil] }
        confirmed.confirm() // no longer shown: nothing happens
    }

    private func sendKey(
        _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow
    ) throws {
        let event = try #require(SharedEvents.key(characters, code: code, modifiers: modifiers))
        window.sendEvent(event)
    }

    @Test func pushSheetFocusesControlsAndTogglesForceWithKeyboard() throws {
        let alerts = AppRecordingAlerts()
        let sheet = PushSheet(choices: choices(), branch: "main")
        sheet.present(on: NSWindow(), alerts: alerts.presenter) { _ in }
        #expect(sheet.window.initialFirstResponder === sheet.branch)
        #expect(sheet.window.firstResponder === sheet.branch)
        #expect(sheet.branch.cell?.showsFirstResponder == true)

        try sendKey("\t", code: KeyPress.tab, to: sheet.window)
        #expect(sheet.window.firstResponder === sheet.target)
        #expect(sheet.branch.cell?.showsFirstResponder == false)
        #expect(sheet.target.cell?.showsFirstResponder == true)

        try sendKey("\t", code: KeyPress.tab, to: sheet.window)
        #expect(sheet.window.firstResponder === sheet.tags)

        try sendKey("\t", code: KeyPress.tab, to: sheet.window)
        #expect(sheet.window.firstResponder === sheet.force)

        try sendKey(" ", code: KeyPress.space, to: sheet.window)
        #expect(sheet.force.state == .on)
        #expect(sheet.defaultButton.hasDestructiveAction)
        #expect(sheet.choice?.force == true)

        try sendKey("\t", code: KeyPress.tab, to: sheet.window)
        #expect(sheet.window.firstResponder === sheet.cancelButton)

        try sendKey("\t", code: KeyPress.tab, to: sheet.window)
        #expect(sheet.window.firstResponder === sheet.defaultButton)

        try sendKey("\t", code: KeyPress.tab, to: sheet.window)
        #expect(sheet.window.firstResponder === sheet.branch)

        try sendKey("\u{19}", code: KeyPress.tab, modifiers: .shift, to: sheet.window)
        #expect(sheet.window.firstResponder === sheet.defaultButton)

        sheet.window.makeFirstResponder(nil)
        try sendKey("\t", code: KeyPress.tab, to: sheet.window)
        #expect(sheet.window.firstResponder === sheet.branch)
    }

    @Test func fetchAndPullSheetsKeepEnabledControlsInKeyLoop() throws {
        let alerts = AppRecordingAlerts()
        let fetch = FetchSheet(choices: choices())
        fetch.present(on: NSWindow(), alerts: alerts.presenter) { _ in }
        #expect(fetch.window.initialFirstResponder === fetch.all)
        #expect(fetch.window.firstResponder === fetch.all)
        #expect(!fetch.remote.canBecomeKeyView)
        try sendKey(" ", code: KeyPress.space, to: fetch.window)
        #expect(fetch.all.state == .off)
        #expect(fetch.remote.isEnabled)
        #expect(fetch.remote.canBecomeKeyView)
        try sendKey("\u{19}", code: KeyPress.tab, modifiers: .shift, to: fetch.window)
        #expect(fetch.window.firstResponder === fetch.remote)

        let pull = PullSheet(choices: choices(), into: "feature")
        pull.present(on: NSWindow(), alerts: alerts.presenter) { _ in }
        #expect(pull.window.firstResponder === pull.remote)
        try sendKey("\t", code: KeyPress.tab, to: pull.window)
        #expect(pull.window.firstResponder === pull.branch)
        try sendKey("\t", code: KeyPress.tab, to: pull.window)
        #expect(pull.window.firstResponder === pull.mode)
        try sendKey("\t", code: KeyPress.tab, to: pull.window)
        #expect(pull.window.firstResponder === pull.autostash)
    }

    @Test func popUpMenusOpenWithSpaceAndVerticalArrows() throws {
        #expect(SyncForm.opensPopUp(try #require(SharedEvents.key(" ", code: KeyPress.space))))
        #expect(SyncForm.opensPopUp(try #require(SharedEvents.key("\u{F700}", code: KeyPress.upArrow))))
        #expect(SyncForm.opensPopUp(try #require(SharedEvents.key("\u{F701}", code: KeyPress.downArrow))))
        #expect(!SyncForm.opensPopUp(try #require(SharedEvents.key("\u{F702}", code: KeyPress.leftArrow))))
        #expect(!SyncForm.opensPopUp(try #require(SharedEvents.key(" ", code: KeyPress.space, modifiers: .command))))
    }
}
