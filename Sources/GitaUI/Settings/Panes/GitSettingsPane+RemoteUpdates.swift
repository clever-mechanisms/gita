import AppKit

/// Bridges `GitSettingsPane`'s Remote Updates UI to `Preference` keys and `RemoteMonitor` status callbacks.
@MainActor
struct RemoteUpdatesSettingsAdapter {
    static let intervalOptions = RemoteCheckCadence.allCases.map(\.rawValue)
    static let defaultInterval = RemoteCheckCadence.default.rawValue

    var defaults: UserDefaults
    var statusSummary: () -> String
    var onChange: () -> Void = {}

    var checkRemotes: Bool {
        get { Preference.remoteCheck.bool(defaults) }
        nonmutating set { write(newValue, preference: .remoteCheck) }
    }

    var autoFetch: Bool {
        get { Preference.remoteAutoFetch.bool(defaults) }
        nonmutating set { write(newValue, preference: .remoteAutoFetch) }
    }

    var fetchIntervalMinutes: Int {
        get { RemoteCheckCadence(stored: Preference.remoteCheckCadence.int(defaults)).rawValue }
        nonmutating set { write(RemoteCheckCadence(stored: newValue).rawValue, preference: .remoteCheckCadence) }
    }

    var fetchOnWindowFront: Bool {
        get { Preference.remoteCheckOnFocus.bool(defaults) }
        nonmutating set { write(newValue, preference: .remoteCheckOnFocus) }
    }

    var checkScope: RemoteCheckScope {
        get { RemoteCheckScope(stored: Preference.remoteCheckScope.string(defaults)) }
        nonmutating set { write(newValue.rawValue, preference: .remoteCheckScope) }
    }

    var pauseOnConstrainedNetwork: Bool {
        get { Preference.remotePauseOnLowData.bool(defaults) }
        nonmutating set { write(newValue, preference: .remotePauseOnLowData) }
    }

    private func write(_ value: Any, preference: Preference) {
        preference.set(value, defaults)
        onChange()
    }
}

/// Controls and layout for `Settings ▸ Git ▸ Remote Updates`.
@MainActor
final class RemoteUpdatesControls {
    let checkRemotes: AccentSwitch
    let autoFetch: AccentSwitch
    let fetchInterval: ActionPopUpButton
    let fetchOnWindowFront: NSButton
    let checkScope: ActionSegmentedControl
    let pauseOnConstrained: NSButton
    let statusLabel: NSTextField
    let infoButton: NSButton
    private(set) var infoPopover: NSPopover?
    private let adapter: RemoteUpdatesSettingsAdapter

    init(adapter: RemoteUpdatesSettingsAdapter) {
        self.adapter = adapter
        var applyCheck: (Bool) -> Void = { _ in }
        var applyAutoFetch: (Bool) -> Void = { _ in }
        var applyInterval: (Int) -> Void = { _ in }
        var applyScope: (Int) -> Void = { _ in }
        checkRemotes = AccentSwitch(accessibility: String(localized: "Check remotes for new commits")) {
            applyCheck($0)
        }
        autoFetch = AccentSwitch(accessibility: String(localized: "Fetch automatically")) {
            applyAutoFetch($0)
        }
        fetchInterval = SettingsForm.popup(accessibility: String(localized: "Every")) { popup in
            applyInterval(popup.selectedItem?.tag ?? RemoteUpdatesSettingsAdapter.defaultInterval)
        }
        fetchOnWindowFront = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkScope = SettingsForm.segmented(
            RemoteCheckScope.allCases.map(\.localizedTitle),
            accessibility: String(localized: "Check in")
        ) { applyScope($0) }
        pauseOnConstrained = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        statusLabel = SettingsForm.note()
        infoButton = NSButton()
        configureControls()
        applyCheck = { [weak self] on in
            self?.adapter.checkRemotes = on
            self?.refresh()
        }
        applyAutoFetch = { [weak self] on in
            self?.adapter.autoFetch = on
            self?.refresh()
        }
        applyInterval = { [weak self] minutes in
            self?.adapter.fetchIntervalMinutes = minutes
            self?.refresh()
        }
        applyScope = { [weak self] index in
            guard RemoteCheckScope.allCases.indices.contains(index) else { return }
            self?.adapter.checkScope = RemoteCheckScope.allCases[index]
            self?.refresh()
        }
    }

    private func configureControls() {
        checkRemotes.setAccessibilityIdentifier("settings.remoteUpdates.check")
        autoFetch.setAccessibilityIdentifier("settings.remoteUpdates.autoFetch")
        for minutes in RemoteUpdatesSettingsAdapter.intervalOptions {
            fetchInterval.addItem(withTitle: String(localized: "\(minutes) minutes"))
            fetchInterval.lastItem?.tag = minutes
        }
        fetchInterval.setAccessibilityIdentifier("settings.remoteUpdates.interval")
        fetchOnWindowFront.target = self
        fetchOnWindowFront.action = #selector(toggleWindowFront)
        fetchOnWindowFront.setAccessibilityLabel(
            String(localized: "Also when a window comes forward and the last fetch is older"))
        fetchOnWindowFront.setAccessibilityIdentifier("settings.remoteUpdates.windowFront")
        checkScope.setAccessibilityIdentifier("settings.remoteUpdates.scope")
        pauseOnConstrained.target = self
        pauseOnConstrained.action = #selector(togglePauseConstrained)
        pauseOnConstrained.setAccessibilityLabel(
            String(localized: "Pause on Low Data Mode, expensive networks and Low Power Mode"))
        pauseOnConstrained.setAccessibilityIdentifier("settings.remoteUpdates.pauseConstrained")
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("settings.remoteUpdates.status")
        infoButton.bezelStyle = .inline
        infoButton.isBordered = false
        infoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        infoButton.contentTintColor = Theme.secondaryText
        infoButton.target = self
        infoButton.action = #selector(toggleInfo)
        infoButton.toolTip = String(localized: "About remote checks and security")
        infoButton.setAccessibilityLabel(String(localized: "About remote checks and security"))
        infoButton.setAccessibilityIdentifier("settings.remoteUpdates.info")
    }

    func makeGroup() -> SettingsGroup {
        SettingsGroup(
            String(localized: "Remote Updates"),
            [
                SettingsRow(
                    String(localized: "Check remotes for new commits"), [checkRemotes],
                    subtitle: String(
                        localized:
                            """
                            Asks each remote which branch tips moved (git ls-remote). Downloads nothing and \
                            writes nothing to your repositories.
                            """
                    )),
                SettingsRow(
                    String(localized: "Fetch automatically"), [autoFetch],
                    subtitle: String(
                        localized:
                            """
                            Downloads commits and updates remote-tracking branches (origin/…) only. Your \
                            branches, staged changes and files are never touched.
                            """
                    )),
                SettingsRow(String(localized: "Every"), [fetchInterval]),
                SettingsRow(
                    String(localized: "Also when a window comes forward and the last fetch is older"),
                    [fetchOnWindowFront]),
                SettingsRow(String(localized: "Check in"), [checkScope]),
                SettingsRow(
                    String(localized: "Pause on Low Data Mode, expensive networks and Low Power Mode"),
                    [pauseOnConstrained]),
                SettingsRow(String(localized: "Last checked"), [statusLabel, infoButton]),
            ])
    }

    func refresh() {
        let checking = adapter.checkRemotes
        let fetching = adapter.autoFetch
        let anyActive = checking || fetching
        checkRemotes.setOn(checking)
        autoFetch.setOn(fetching)
        fetchInterval.selectItem(withTag: adapter.fetchIntervalMinutes)
        fetchInterval.isEnabled = anyActive
        fetchOnWindowFront.state = adapter.fetchOnWindowFront ? .on : .off
        fetchOnWindowFront.isEnabled = anyActive
        checkScope.selectedSegment =
            RemoteCheckScope.allCases.firstIndex(of: adapter.checkScope) ?? 1
        checkScope.isEnabled = anyActive
        pauseOnConstrained.state = adapter.pauseOnConstrainedNetwork ? .on : .off
        pauseOnConstrained.isEnabled = anyActive
        let summary = adapter.statusSummary()
        statusLabel.stringValue = summary
        statusLabel.toolTip = summary
    }

    @objc private func toggleWindowFront() {
        adapter.fetchOnWindowFront = fetchOnWindowFront.state == .on
        refresh()
    }

    @objc private func togglePauseConstrained() {
        adapter.pauseOnConstrainedNetwork = pauseOnConstrained.state == .on
        refresh()
    }

    @objc func toggleInfo() {
        if let infoPopover, infoPopover.isShown {
            infoPopover.close()
            return
        }
        let text = String(
            localized:
                """
                Plain http:// remotes are refused for security and are never checked in the background. \
                Authentication failures pause background checks for that remote until you run a manual Fetch.
                """
        )
        let popover = SettingsTextPopover.make(text, font: Theme.body, width: 320)
        popover.show(relativeTo: infoButton.bounds, of: infoButton, preferredEdge: .maxY)
        infoPopover = popover
    }
}

extension GitSettingsPane {
    func refreshRemoteUpdates() {
        remoteUpdates.refresh()
    }
}
