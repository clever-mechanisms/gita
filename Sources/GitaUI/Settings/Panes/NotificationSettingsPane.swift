import AppKit
import GitaCore

/// Settings ▸ Notifications: the main switch (which asks macOS for permission) and one switch per event, grouped by
/// where the event comes from (GitHub, Vercel, the coding agents). Each event says what triggers it under its "?", and
/// an event whose integration is off (in Integrations or AI Agents) is greyed out.
@MainActor
final class NotificationSettingsPane: SettingsPaneContent {
    /// The main switch's request for permission: none, macOS asking (the switch waits), or the last answer that
    /// counted was no (its tooltip says where to allow them).
    enum Authorization: Equatable {
        case idle, asking, denied

        /// macOS answered; `counts` is false when a newer change of the switch (in any window) overtook the
        /// request, so its no says nothing about the setting now.
        static func answered(_ allowed: Bool, counts: Bool) -> Self { counts && !allowed ? .denied : .idle }
    }

    /// Bumped on every main switch change, in every window: an older permission answer never overrides a newer
    /// choice.
    private static var revision = 0
    private(set) var authorization = Authorization.idle
    private(set) lazy var allowSwitch = AccentSwitch(accessibility: String(localized: "Allow notifications")) {
        [weak self] on in self?.setAllowed(on)
    }
    private(set) var categories: [(preference: Preference, toggle: AccentSwitch)] = []
    /// The integration each event needs, with the note that says it is off.
    private var sources: [(toggle: AccentSwitch, integration: Integration, note: NSTextField)] = []
    private(set) lazy var testButton = SettingsForm.button(String(localized: "Send Test"), symbol: "bell.badge") {
        [weak self] in self?.sendTest()
    }
    /// Says why the test sent nothing.
    private(set) lazy var testNote = SettingsForm.note()

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        allowSwitch.setAccessibilityIdentifier("settings.notifications")
        let systemSettings = SettingsForm.button(String(localized: "Notification Settings…"), symbol: "bell") {
            [weak self] in self?.openSystemSettings()
        }
        setGroups([
            SettingsGroup(
                nil,
                [
                    SettingsRow(String(localized: "Allow notifications"), [allowSwitch]),
                    SettingsRow(String(localized: "Banners and sounds"), [systemSettings]),
                    SettingsRow(
                        String(localized: "Test notifications"), [testNote, testButton],
                        help: String(
                            localized: "Sends a sample from a coding agent, GitHub and Vercel, each with its mark.")),
                ]),
            group(String(localized: "Pull requests"), mark: .github, integration: .github, pullRequestRows()),
            group(String(localized: "Checks"), mark: .github, integration: .github, checkRows()),
            group(String(localized: "Deployments"), mark: .vercel, integration: .vercel, deploymentRows()),
            group(String(localized: "Coding agents"), mark: nil, integration: .agents, agentRows()),
        ])
    }

    private typealias Event = (title: String, preference: Preference, help: String)

    private func pullRequestRows() -> [Event] {
        [
            (
                String(localized: "New pull request on my repositories"), .notifyPullRequestOpened,
                String(localized: "Someone else opens a pull request on a repository you have open in Gitā.")
            ),
            (
                String(localized: "My review is requested"), .notifyReviewRequested,
                String(localized: "A pull request asks you for a review.")
            ),
            (
                String(localized: "Pull request merged"), .notifyPullRequestMerged,
                String(localized: "Someone else merges a pull request on your repositories; the notification says who.")
            ),
        ]
    }
    private func checkRows() -> [Event] {
        [
            (
                String(localized: "Checks failed on my branches"), .notifyChecksFailed,
                String(localized: "A GitHub Actions run fails on one of your branches.")
            ),
            (
                String(localized: "Checks pass again"), .notifyChecksFixed,
                String(localized: "The checks of a branch that was failing pass again.")
            ),
        ]
    }
    private func deploymentRows() -> [Event] {
        [
            (
                String(localized: "Preview deployment ready"), .notifyPreviewReady,
                String(localized: "Vercel finishes a preview deployment; open the preview from the notification.")
            ),
            (
                String(localized: "Production deployed"), .notifyProductionDeployed,
                String(localized: "A new production deployment of a linked Vercel project goes live.")
            ),
            (
                String(localized: "Production alert"), .notifyVercelAlert,
                String(
                    localized:
                        """
                        Vercel raises an alert on a linked project's production, such as a sudden rise in \
                        errors. You hear about each new alert once.
                        """
                )
            ),
        ]
    }
    private func agentRows() -> [Event] {
        [
            (
                String(localized: "An agent needs input"), .notifyAgentNeedsInput,
                String(
                    localized:
                        """
                        Claude Code, Codex or opencode stops to ask you something, such as a permission. \
                        Install the agent's hooks in AI Agents for the fastest notice.
                        """
                )
            ),
            (
                String(localized: "An agent finished"), .notifyAgentFinished,
                String(localized: "A coding agent finishes its turn and waits for you.")
            ),
        ]
    }

    private func group(
        _ title: String, mark: BrandMarks.Brand?, integration: Integration, _ events: [Event]
    )
        -> SettingsGroup
    {
        let group = SettingsGroup(title, events.map { row($0, integration: integration) })
        let image =
            mark.map { BrandMarks.image($0, size: SettingsForm.markSize) }
            ?? Deck.symbol(SettingsPane.agentsSymbol, size: SettingsForm.markSize - 2, color: Theme.secondaryText)
        if let image { SettingsForm.mark(group.titleLabel, image, title) }
        return group
    }
    private func row(_ event: Event, integration: Integration) -> SettingsRow {
        let toggle = toggle(event.preference, accessibility: event.title)
        let note = SettingsForm.note()
        categories.append((event.preference, toggle))
        sources.append((toggle, integration, note))
        return SettingsRow(event.title, [note, toggle], help: event.help)
    }

    override func refresh() {
        let on = Preference.notifications.bool(defaults)
        if authorization != .asking { allowSwitch.setOn(on) }
        allowSwitch.isEnabled = authorization != .asking
        allowSwitch.toolTip =
            authorization == .denied
            ? String(localized: "Allow notifications in System Settings to receive updates.") : nil
        for (preference, toggle) in categories {
            toggle.setOn(preference.bool(defaults))
            toggle.isEnabled = on
        }
        for source in sources {
            let available = source.integration.isEnabled(defaults)
            source.note.stringValue = available ? "" : Self.offNote(source.integration)
            if !available { source.toggle.isEnabled = false }
        }
    }

    /// Where an integration that is off is switched back on.
    static func offNote(_ integration: Integration) -> String {
        integration == .agents ? String(localized: "Off in AI Agents") : String(localized: "Off in Integrations")
    }

    private func setAllowed(_ enabled: Bool) {
        Self.revision += 1
        let revision = Self.revision
        guard enabled else {
            Preference.notifications.set(false, defaults)
            refresh()
            return
        }
        authorization = .asking
        refresh()
        let authorize = environment.system.authorizeNotifications
        let defaults = defaults
        Task { [weak self] in
            let allowed = await authorize()
            // Another window may have changed this shared setting while the macOS request was open.
            let counts = revision == Self.revision
            if counts { Preference.notifications.set(allowed, defaults) }
            guard let self else { return }
            self.authorization = .answered(allowed, counts: counts)
            self.refresh()
        }
    }
    private func sendTest() {
        testButton.isEnabled = false
        testNote.stringValue = ""
        let send = environment.system.sendTestNotification
        Task { [weak self] in
            let sent = await send()
            guard let self else { return }
            self.testButton.isEnabled = true
            self.testNote.stringValue =
                sent ? "" : String(localized: "Allow notifications in System Settings to receive updates.")
        }
    }
    /// System Settings ▸ Notifications, on Gitā's own page when the app has a bundle identifier.
    static func systemSettingsURL(bundleIdentifier: String?) -> URL? {
        let base = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return URL(string: base) }
        return URL(string: base + "?id=" + bundleIdentifier)
    }
    private func openSystemSettings() {
        if let url = Self.systemSettingsURL(bundleIdentifier: environment.system.bundleIdentifier) {
            environment.system.openURL(url)
        }
    }
}
