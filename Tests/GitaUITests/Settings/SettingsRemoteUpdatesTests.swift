import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Settings Git Remote Updates") @MainActor
struct SettingsRemoteUpdatesTests {
    @Test func defaultsAndControlsEnablementFollowRemoteUpdatesRules() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let status = "gita-app 2 min ago · gita-web offline"
        var environment = recorder.environment
        environment.app.remoteUpdatesStatus = { status }
        let pane = GitSettingsPane(environment: environment)
        pane.refresh()

        let controls = pane.remoteUpdates
        #expect(controls.checkRemotes.isOn)
        #expect(!controls.autoFetch.isOn)
        #expect(controls.fetchInterval.isEnabled)
        #expect(controls.fetchOnWindowFront.isEnabled)
        #expect(controls.fetchOnWindowFront.state == .on)
        #expect(controls.checkScope.isEnabled)
        #expect(controls.checkScope.selectedSegment == 1)
        #expect(controls.pauseOnConstrained.isEnabled)
        #expect(controls.pauseOnConstrained.state == .on)
        #expect(controls.statusLabel.stringValue == status)
        #expect(controls.statusLabel.toolTip == status)
        #expect(pane.view(for: .remoteUpdates) === pane.remoteUpdatesGroup)

        // Cadence and focus remain available when auto-fetch is also enabled.
        controls.autoFetch.settingsPress()
        #expect(Preference.remoteAutoFetch.bool(recorder.defaults))
        #expect(controls.fetchInterval.isEnabled)
        #expect(controls.fetchOnWindowFront.isEnabled)

        controls.fetchInterval.selectItem(withTag: 30)
        controls.fetchInterval.onChange(controls.fetchInterval)
        #expect(Preference.remoteCheckCadence.int(recorder.defaults) == 30)

        controls.fetchOnWindowFront.state = .off
        controls.fetchOnWindowFront.sendAction(
            controls.fetchOnWindowFront.action, to: controls.fetchOnWindowFront.target)
        #expect(!Preference.remoteCheckOnFocus.bool(recorder.defaults))

        controls.checkScope.settingsChoose(0)
        #expect(Preference.remoteCheckScope.string(recorder.defaults) == RemoteCheckScope.frontTabOnly.rawValue)

        controls.pauseOnConstrained.state = .off
        controls.pauseOnConstrained.sendAction(
            controls.pauseOnConstrained.action, to: controls.pauseOnConstrained.target)
        #expect(!Preference.remotePauseOnLowData.bool(recorder.defaults))

        // Turning both off disables scope and constrained-network pause and persists Preference.remoteCheck = false.
        controls.autoFetch.settingsPress()
        controls.checkRemotes.settingsPress()
        #expect(!Preference.remoteCheck.bool(recorder.defaults))
        #expect(!controls.fetchInterval.isEnabled && !controls.fetchOnWindowFront.isEnabled)
        #expect(!controls.checkScope.isEnabled)
        #expect(!controls.pauseOnConstrained.isEnabled)
        #expect(!recorder.preferenceChanges.isEmpty)
    }

    @Test func infoButtonShowsSecurityAndAuthExplanationPopover() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = GitSettingsPane(environment: recorder.environment)
        let window = recorder.window()
        window.contentView?.addSubview(pane.view)
        window.contentView?.layoutSubtreeIfNeeded()
        pane.remoteUpdates.toggleInfo()
        let popover = try #require(pane.remoteUpdates.infoPopover)
        #expect(popover.contentViewController != nil)
        pane.remoteUpdates.toggleInfo()
        window.close()
    }

    @Test func adapterClampsInvalidIntervalAndDefaults() throws {
        let suite = "GitaUITests.RemoteAdapter.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var changed = 0
        let adapter = RemoteUpdatesSettingsAdapter(
            defaults: defaults, statusSummary: { "ok" }, onChange: { changed += 1 })
        Preference.remoteCheckCadence.set(999, defaults)
        #expect(adapter.fetchIntervalMinutes == 15)
        adapter.fetchIntervalMinutes = 42
        #expect(adapter.fetchIntervalMinutes == 15)
        adapter.fetchIntervalMinutes = 5
        #expect(adapter.fetchIntervalMinutes == 5)
        #expect(changed == 2)
    }

    @Test func settingsHooksBindToRemoteMonitorStatusLineAndPreferenceKeys() async throws {
        let suite = "GitaUITests.RemoteSettingsHooks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        Preference.registerDefaults(in: defaults)

        let repository = try TemporaryRepository()
        let model = AppModel(defaults: defaults)
        var snapshot = RepositorySnapshot(
            root: repository.url, branch: "main", head: String(repeating: "a", count: 40), changes: [], commits: [],
            references: [], worktrees: [], stashes: [], remoteURL: "https://example.invalid/repo.git",
            gitDirectory: repository.url.appendingPathComponent(".git"),
            commonGitDirectory: repository.url.appendingPathComponent(".git"))
        snapshot.remoteURLs = ["origin": "https://example.invalid/repo.git"]

        var env = RemoteMonitorEnvironment()
        env.startsSystemMonitors = false
        let monitor = RemoteMonitor(environment: env)
        monitor.register(
            model: model, root: repository.url, service: GitService(root: repository.url), snapshot: snapshot,
            defaults: defaults)
        defer { monitor.unregister(model: model) }

        let activeLine = SettingsAppHooks.remoteUpdatesStatusText(
            roots: [repository.url], defaults: defaults, monitor: monitor)
        #expect(activeLine.contains(repository.url.lastPathComponent))
        #expect(activeLine.contains("Waiting to check remotes"))

        monitor.updateNetworkStatus(.offline)
        let offlineLine = SettingsAppHooks.remoteUpdatesStatusText(
            roots: [repository.url], defaults: defaults, monitor: monitor)
        #expect(offlineLine.contains("Offline"))

        // Toggling Preference.remoteCheck via RemoteUpdatesControls switches RemoteMonitor.shared to .off.
        RemoteMonitor.shared.register(
            model: model, root: repository.url, service: GitService(root: repository.url), snapshot: snapshot,
            defaults: defaults)
        defer { RemoteMonitor.shared.unregister(model: model) }
        let pane = GitSettingsPane(
            environment: SettingsEnvironment(
                defaults: defaults,
                app: SettingsAppHooks(
                    remoteUpdatesStatus: {
                        SettingsAppHooks.remoteUpdatesStatusText(roots: [repository.url], defaults: defaults)
                    })))
        pane.refresh()
        pane.remoteUpdates.checkRemotes.settingsPress()
        #expect(!Preference.remoteCheck.bool(defaults))
        let isMonitorOff: Bool =
            if case .off = RemoteMonitor.shared.state(for: repository.url).phase { true } else { false }
        #expect(isMonitorOff)
        let offText = SettingsAppHooks.remoteUpdatesStatusText(roots: [repository.url], defaults: defaults)
        #expect(offText == "Remote checks off")

        let emptyText = SettingsAppHooks.remoteUpdatesStatusText(roots: [], defaults: .standard, monitor: monitor)
        #expect(emptyText == "Checks remotes while repositories are open.")
    }
}
