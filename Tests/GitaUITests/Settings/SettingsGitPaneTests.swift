import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Settings History, Git and Menu Bar panes") @MainActor
struct SettingsGitPaneTests {
    @Test func historySwitchesSaveAndNotify() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        Preference.registerDefaults(in: recorder.defaults)
        let pane = HistorySettingsPane(environment: recorder.environment)
        pane.refresh()
        #expect(pane.details.isOn)
        #expect(pane.avatars.isOn)
        #expect(pane.mergeLabel.isOn)
        #expect(!pane.squashMerges.isOn)
        #expect(pane.size.selectedItem?.tag == HistoryZoom.actual)

        pane.details.settingsPress()
        #expect(!Preference.showsHistoryDetails.bool(recorder.defaults))
        pane.avatars.settingsPress()
        #expect(!Preference.showsAvatars.bool(recorder.defaults))
        pane.avatars.settingsPress()
        #expect(recorder.avatarChanges == 2)
        pane.mergeLabel.settingsPress()
        #expect(!Preference.showsMergeLabel.bool(recorder.defaults))
        #expect(recorder.preferenceChanges == [false, true, false])

        pane.squashMerges.settingsPress()
        #expect(Preference.squashMergesAsMerges.bool(recorder.defaults))
        pane.collapseMerged.settingsPress()
        #expect(Preference.collapsesMergedCommits.bool(recorder.defaults))
        // Each merge setting turns its illustration to match.
        pane.collapseMerged.settingsPress()
        #expect(!pane.collapseIllustration.isOn)
        pane.squashMerges.settingsPress()
        #expect(!pane.squashIllustration.isOn)
    }

    @Test func stillIllustrationsHoldTheSettingAndPlayingOnesLoop() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = HistorySettingsPane(environment: recorder.environment)
        pane.collapseIllustration.plays = false
        pane.squashIllustration.plays = false
        recorder.defaults.set(false, forKey: Preference.collapsesMergedCommits.rawValue)
        recorder.defaults.set(true, forKey: Preference.squashMergesAsMerges.rawValue)
        pane.refresh()
        #expect(!pane.collapseIllustration.isOn)
        #expect(pane.squashIllustration.isOn)
        #expect(pane.collapseIllustration.progress == 1)

        // A move eases in only while the scene plays; stopped, it draws the new state at once.
        let playing = MergeIllustrationView(.squash, isOn: false)
        playing.plays = true
        playing.advance()
        #expect(playing.isOn)
        #expect(playing.progress == 1, "not started: nothing would ease it in")
        playing.start()
        playing.advance()
        #expect(!playing.isOn && playing.progress == 0)
        playing.stop()
        #expect(playing.progress == 1)
        // Every state of both scenes draws: on, off, and halfway through a move.
        for kind in MergeIllustrationView.Kind.allCases {
            for isOn in [true, false] {
                let view = MergeIllustrationView(kind, isOn: isOn)
                view.frame = NSRect(x: 0, y: 0, width: 300, height: MergeIllustrationView.height)
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                view.plays = true
                view.start()
                view.advance()
                view.cacheDisplay(in: view.bounds, to: rep)
                view.stop()
                #expect(view.isOn != isOn)
                #expect(view.accessibilityLabel()?.contains(kind.title) == true)
            }
        }
    }

    @Test func pullModeAndMergeDefaultSaveAndTurnTheirIllustrations() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        Preference.registerDefaults(in: recorder.defaults)
        let pane = GitSettingsPane(environment: recorder.environment)
        pane.pullIllustration.plays = false
        pane.mergeIllustration.plays = false
        pane.refresh()
        #expect(pane.pullMode.indexOfSelectedItem == 0)
        #expect(pane.pullIllustration.choice == .pull(.fastForwardOnly))
        #expect(pane.speedUp.isOn == Preference.speedsUpSlowRepositories.bool(recorder.defaults))
        #expect(pane.mergeIllustration.choice == .merge(.automatic))

        pane.pullMode.selectItem(at: GitPullMode.allCases.firstIndex(of: .rebase) ?? 0)
        pane.pullMode.onChange(pane.pullMode)
        #expect(Preference.pullMode.string(recorder.defaults) == GitPullMode.rebase.rawValue)
        #expect(pane.pullIllustration.choice == .pull(.rebase))
        pane.mergeMode.selectItem(at: GitMergeMode.allCases.firstIndex(of: .noFastForward) ?? 0)
        pane.mergeMode.onChange(pane.mergeMode)
        #expect(Preference.mergeMode.string(recorder.defaults) == GitMergeMode.noFastForward.rawValue)
        #expect(pane.mergeIllustration.choice == .merge(.noFastForward))

        // Every choice plays both situations, before and after, and draws every step still and halfway.
        let choices: [SyncIllustrationView.Choice] =
            GitPullMode.allCases.map { .pull($0) } + GitMergeMode.allCases.map { .merge($0) }
        for choice in choices {
            let view = SyncIllustrationView(choice == choices[0] ? choices[1] : choices[0])
            view.plays = false
            view.frame = NSRect(x: 0, y: 0, width: 300, height: SyncIllustrationView.height)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.show(choice)
            #expect(view.still == .init(choice: choice, situation: .behind, after: false))
            var seen: [SyncScenes.Still] = []
            for moves in [true, false] {
                view.moves = moves
                for _ in 0..<4 {
                    view.advance()
                    seen.append(view.still)
                    for progress in [0.5, 1] as [CGFloat] {
                        view.progress = progress
                        view.cacheDisplay(in: view.bounds, to: rep)
                    }
                }
            }
            #expect(Set(seen.map { "\($0.situation)\($0.after)" }).count == 4)
            #expect(view.progress == 1)
            for situation in SyncScenes.Situation.allCases {
                #expect(!SyncScenes.caption(choice, situation).isEmpty)
                #expect(!SyncScenes.title(choice, situation).isEmpty)
                for after in [false, true] {
                    let history = SyncScenes.history(.init(choice: choice, situation: situation, after: after))
                    let ids = history.map(\.id)
                    // Parents are always further down (or older history), as `git log` lists them.
                    #expect(
                        history.enumerated().allSatisfy { index, commit in
                            commit.parents.allSatisfy { !ids.prefix(index + 1).contains($0) }
                        })
                    #expect(history.filter(\.isHead).count == 1)
                }
                let before = SyncScenes.history(.init(choice: choice, situation: situation, after: false))
                let after = SyncScenes.history(.init(choice: choice, situation: situation, after: true))
                #expect((before == after) == (situation == .behind ? false : SyncScenes.stops(choice, situation)))
            }
        }
        // The three Merge defaults differ: fast-forward only and when-possible part ways once both branches moved.
        func after(_ mode: GitMergeMode, _ situation: SyncScenes.Situation) -> [SceneGraph.Commit] {
            SyncScenes.history(.init(choice: .merge(mode), situation: situation, after: true))
        }
        #expect(after(.automatic, .behind) == after(.fastForwardOnly, .behind))
        #expect(after(.automatic, .diverged) != after(.fastForwardOnly, .diverged))
        #expect(after(.automatic, .behind) != after(.noFastForward, .behind))
    }

    @Test func rowsWithAnExplanationShowItInAPopover() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let history = HistorySettingsPane(environment: recorder.environment)
        #expect(history.view.settingsDescendants(of: SettingsHelpButton.self).count == 3)
        #expect(history.view.settingsDescendants(of: SettingsFeatureCard.self).count == 2)
        let pane = GitSettingsPane(environment: recorder.environment)
        let cards = pane.view.settingsDescendants(of: SettingsChoiceCard.self)
        #expect(cards.map(\.titleLabel.stringValue) == [String(localized: "Pull"), String(localized: "Merge")])
        #expect(cards.allSatisfy { $0.help != nil })
        let helps = pane.view.settingsDescendants(of: SettingsHelpButton.self)
        #expect(helps.count == 8)
        let help = try #require(helps.last)
        #expect(help.toolTip == help.explanation)
        #expect(help.accessibilityHelp() == help.explanation)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 800), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(pane.view)
        help.toggleExplanation()
        #expect(help.popover != nil)
        help.toggleExplanation()
        window.close()
    }

    @Test func historySizeMergedCommitsAndGraphLines() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = HistorySettingsPane(environment: recorder.environment)
        pane.refresh()

        pane.size.selectItem(withTag: 120)
        pane.size.sendAction(pane.size.action, to: pane.size.target)
        #expect(Preference.historyZoomPercent.int(recorder.defaults) == 120)
        #expect(recorder.preferenceChanges == [false])
        pane.size.removeAllItems() // no item: nothing saved
        pane.size.sendAction(pane.size.action, to: pane.size.target)
        #expect(recorder.preferenceChanges == [false])

        pane.mergedCommits.settingsChoose(1)
        #expect(Preference.mergedCommitsOn.string(recorder.defaults) == "hover")
        pane.mergedCommits.onChange(7)
        #expect(Preference.mergedCommitsOn.string(recorder.defaults) == "hover")

        pane.graphLines.settingsChoose(1)
        #expect(recorder.graphLines == [GraphCell.LineStyle.allCases[1]])
        pane.graphLines.onChange(-1)
        #expect(recorder.graphLines.count == 1)

        recorder.defaults.set("hover", forKey: Preference.mergedCommitsOn.rawValue)
        recorder.defaults.set("angled", forKey: Preference.graphLines.rawValue)
        pane.refresh()
        #expect(pane.mergedCommits.selectedSegment == 1)
        #expect(pane.graphLines.selectedSegment == 1)
        recorder.defaults.set("other", forKey: Preference.mergedCommitsOn.rawValue)
        recorder.defaults.set("other", forKey: Preference.graphLines.rawValue)
        pane.refresh()
        #expect(pane.mergedCommits.selectedSegment == 0)
        #expect(pane.graphLines.selectedSegment == 0)
    }

    @Test func globalPerformanceSettingsLoadToggleAndRespectCustomHook() async throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let globalConfig = tempDir.appendingPathComponent("gitconfig")
        let service = RepositoryHealthService(globalConfigURL: globalConfig)

        let pane = GitSettingsPane(environment: recorder.environment, healthService: service)
        #expect(pane.view(for: .performance) === pane.performanceGroup)
        #expect(pane.view(for: .remoteUpdates) === pane.remoteUpdatesGroup)
        pane.refresh()
        try await SettingsWait.until { !pane.performance.state.isBusy }
        #expect(!pane.performance.globalFSMonitor.isOn)
        #expect(pane.performance.globalFSMonitor.isEnabled)
        #expect(!pane.performance.globalUntrackedCache.isOn)
        #expect(pane.performance.globalUntrackedCache.isEnabled)
        #expect(pane.performance.maintenanceCountLabel.stringValue == String(localized: "None registered"))

        pane.performance.globalFSMonitor.settingsPress()
        try await SettingsWait.until { !pane.performance.state.isBusy }
        #expect(pane.performance.globalFSMonitor.isOn)

        pane.performance.globalUntrackedCache.settingsPress()
        try await SettingsWait.until { !pane.performance.state.isBusy }
        #expect(pane.performance.globalUntrackedCache.isOn)

        let persisted = try await service.inspectGlobalDefaults()
        #expect(persisted.fsMonitor == .enabled)
        #expect(persisted.untrackedCache == .enabled)

        let customConfig = """
            [core]
            \tfsmonitor = ./my-hook
            [maintenance]
            \trepo = /tmp/one
            \trepo = /tmp/two
            """
        try Data(customConfig.utf8).write(to: globalConfig)
        pane.refresh()
        try await SettingsWait.until { !pane.performance.state.isBusy }
        #expect(!pane.performance.globalFSMonitor.isEnabled)
        #expect(pane.performance.globalFSMonitorStatus.stringValue == String(localized: "Custom hook"))
        #expect(pane.performance.fsMonitorRow?.subtitleLabel?.stringValue.contains("./my-hook") == true)
        #expect(pane.performance.maintenanceCountLabel.stringValue == String(localized: "\(2) repositories"))
        #expect(GitPerformanceControls.formatMaintenanceCount(1) == String(localized: "1 repository"))
        pane.didDisappear()
    }

    @Test func globalPerformanceSettingsHandleFailureCleanly() async throws {
        struct FailingRunner: CommandRunning {
            func run(
                executable _: String, arguments _: [String], directory _: URL?, timeout _: TimeInterval,
                outputLimit _: Int
            ) async throws -> CommandResult {
                throw CommandError.timedOut
            }
        }
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let service = RepositoryHealthService(runner: FailingRunner())
        let pane = GitSettingsPane(environment: recorder.environment, healthService: service)
        pane.refresh()
        try await SettingsWait.until { !pane.performance.state.isBusy }
        guard case .failed = pane.performance.state else {
            Issue.record("Expected failed state when global config cannot be read")
            return
        }
        #expect(!pane.performance.globalFSMonitor.isEnabled)
        #expect(!pane.performance.globalUntrackedCache.isEnabled)
        #expect(pane.performance.maintenanceCountLabel.stringValue == String(localized: "Unavailable"))
    }

    @Test func menuBarSwitches() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = MenuBarSettingsPane(environment: recorder.environment)
        pane.refresh()
        #expect(pane.workingCount.isOn)
        #expect(pane.attentionDot.isOn)

        pane.workingCount.settingsPress()
        pane.attentionDot.settingsPress()
        #expect(!Preference.menuBarShowsWorkingCount.bool(recorder.defaults))
        #expect(!Preference.menuBarShowsAttentionDot.bool(recorder.defaults))
        pane.refresh()
        #expect(!pane.workingCount.isOn && !pane.attentionDot.isOn)
    }
}

@Suite("Settings Notifications pane", .serialized) @MainActor
struct SettingsNotificationPaneTests {
    @Test func categoriesFollowTheMainSwitch() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        Preference.registerDefaults(in: recorder.defaults)
        let pane = NotificationSettingsPane(environment: recorder.environment)
        pane.refresh()
        #expect(!pane.allowSwitch.isOn)
        #expect(pane.categories.count == 10)
        #expect(pane.categories.allSatisfy { !$0.toggle.isEnabled && $0.toggle.isOn })

        recorder.defaults.set(true, forKey: Preference.notifications.rawValue)
        pane.refresh()
        #expect(pane.allowSwitch.isOn)
        let first = pane.categories[0]
        #expect(first.toggle.isEnabled)
        first.toggle.settingsPress()
        #expect(!first.preference.bool(recorder.defaults))

        pane.allowSwitch.settingsPress()
        #expect(!Preference.notifications.bool(recorder.defaults))
        #expect(pane.categories.allSatisfy { !$0.toggle.isEnabled })
    }

    @Test(arguments: [true, false])
    func turningOnAsksMacOSAndKeepsItsAnswer(_ allowed: Bool) async throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        recorder.notificationAnswer = allowed
        let pane = NotificationSettingsPane(environment: recorder.environment)
        pane.refresh()
        pane.allowSwitch.settingsPress()
        #expect(!pane.allowSwitch.isEnabled)
        try await SettingsWait.until { pane.allowSwitch.isEnabled }
        #expect(pane.allowSwitch.isEnabled)
        #expect(Preference.notifications.bool(recorder.defaults) == allowed)
        #expect(pane.allowSwitch.isOn == allowed)
        #expect((pane.allowSwitch.toolTip == nil) == allowed)
    }

    /// A newer choice in another window wins over an older permission request: its late no neither sets the
    /// setting nor says notifications were denied.
    @Test func aStaleAnswerLeavesTheNewerChoiceAndNoDeniedNote() async throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let held = SharedFlag()
        held.value = true
        var environment = recorder.environment
        environment.system.authorizeNotifications = {
            while held.value { try? await Task.sleep(for: .milliseconds(5)) }
            return false
        }
        let asking = NotificationSettingsPane(environment: environment)
        let other = NotificationSettingsPane(environment: recorder.environment)
        asking.refresh()
        other.refresh()
        asking.allowSwitch.settingsPress()
        #expect(asking.authorization == .asking && !asking.allowSwitch.isEnabled)
        other.allowSwitch.settingsPress()
        try await SettingsWait.until { other.authorization == .idle && other.allowSwitch.isEnabled }
        #expect(Preference.notifications.bool(recorder.defaults))
        held.value = false
        try await SettingsWait.until { asking.allowSwitch.isEnabled }
        #expect(Preference.notifications.bool(recorder.defaults), "the newer choice stays")
        #expect(asking.authorization == .idle && asking.allowSwitch.toolTip == nil)
        #expect(asking.allowSwitch.isOn)
        #expect(NotificationSettingsPane.Authorization.answered(false, counts: true) == .denied)
        #expect(NotificationSettingsPane.Authorization.answered(true, counts: true) == .idle)
        #expect(NotificationSettingsPane.Authorization.answered(false, counts: false) == .idle)
    }

    @Test(arguments: [true, false])
    func testButtonSendsSamplesAndSaysWhenNotAllowed(_ allowed: Bool) async throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        recorder.testNotificationAnswer = allowed
        let pane = NotificationSettingsPane(environment: recorder.environment)
        pane.testButton.performClick(nil)
        #expect(!pane.testButton.isEnabled)
        try await SettingsWait.until { pane.testButton.isEnabled }
        #expect(recorder.testNotificationsSent == 1)
        #expect(pane.testNote.stringValue.isEmpty == allowed)
    }

    @Test func notificationSettingsOpenOnTheAppsOwnPage() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = NotificationSettingsPane(environment: recorder.environment)
        let button = try #require(pane.view.settingsDescendants(of: ActionButton.self).first)
        button.performClick(nil)
        #expect(
            recorder.openedURLs.map(\.absoluteString) == [
                "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id="
                    + "dev.clevermechanisms.Gita.tests"
            ])
        let base = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        #expect(NotificationSettingsPane.systemSettingsURL(bundleIdentifier: nil)?.absoluteString == base)
        #expect(NotificationSettingsPane.systemSettingsURL(bundleIdentifier: "")?.absoluteString == base)
    }
}
