import AppKit
import GitaCore

/// Settings ▸ Integrations: GitHub and Vercel, each switchable, refreshing on its own or not, with its account and the
/// active repository's status. The coding agents, Orca and their hooks live in AI Agents.
@MainActor
final class IntegrationsSettingsPane: SettingsPaneContent {
    /// Accounts are read again when the pane appears this long after the last check.
    private static let accountRecheckInterval: TimeInterval = 60

    /// An integration's on/off switch.
    private(set) var integrationSwitches: [Integration: AccentSwitch] = [:]
    /// GitHub's and Vercel's "Refresh automatically".
    private(set) var refreshSwitches: [Integration: AccentSwitch] = [:]
    let githubAccount = SettingsStatus()
    let githubRepository = SettingsStatus()
    private(set) lazy var githubRepositoryRow = SettingsRow("", [githubRepository])
    private lazy var githubGroup = SettingsGroup(
        "GitHub",
        [
            integrationRow(.github, String(localized: "Pull requests, workflows and checks")),
            refreshRow(.github, .providerRefresh),
            SettingsRow(String(localized: "Account"), [githubAccount]), githubRepositoryRow,
        ])
    let vercelAccount = SettingsStatus()
    let vercelRepository = SettingsStatus()
    private(set) lazy var vercelRepositoryRow = SettingsRow("", [vercelRepository])
    private lazy var vercelGroup = SettingsGroup(
        "Vercel",
        [
            integrationRow(.vercel, String(localized: "Deployments and previews")),
            refreshRow(.vercel, .vercelRefresh),
            SettingsRow(String(localized: "Account"), [vercelAccount]), vercelRepositoryRow,
        ])
    private lazy var follower = ActiveModelFollower { [weak self] change in
        if change == .providers || change == .repository { self?.refresh() }
    }
    /// What one read of the accounts found, and when.
    struct AccountsRead {
        var github: CLIAccountProbe.Account
        var vercel: CLIAccountProbe.Account
        var at: Date
    }
    /// The accounts' read: none yet, a read running (what the last one found stays on screen meanwhile), or read.
    enum AccountsCheck {
        case unchecked
        case checking(Task<Void, Never>, last: AccountsRead?)
        case checked(AccountsRead)

        var last: AccountsRead? {
            switch self {
            case .unchecked: nil
            case .checking(_, let last): last
            case .checked(let read): read
            }
        }
        var isChecking: Bool { if case .checking = self { true } else { false } }
        /// Shown again: read when nothing has been read yet or the last read is older than `interval`.
        func isDue(at now: Date, interval: TimeInterval) -> Bool {
            last.map { now.timeIntervalSince($0.at) > interval } ?? true
        }
        /// The read stopped (the pane went away, or a new read replaces it): back to what was read before it.
        var stopped: Self {
            guard case .checking(_, let last) = self else { return self }
            return last.map(Self.checked) ?? .unchecked
        }
        var task: Task<Void, Never>? { if case .checking(let task, _) = self { task } else { nil } }
    }
    private(set) var accounts = AccountsCheck.unchecked
    /// Between didAppear and didDisappear: coming back to the front reads the accounts again.
    private var isShown = false

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        showAccounts()
        SettingsForm.mark(githubGroup.titleLabel, BrandMarks.image(.github, size: SettingsForm.markSize), "GitHub")
        SettingsForm.mark(vercelGroup.titleLabel, BrandMarks.image(.vercel, size: SettingsForm.markSize), "Vercel")
        setGroups([githubGroup, vercelGroup])
    }
    isolated deinit { accounts.task?.cancel() }

    /// The switch that turns an integration on or off as a whole.
    private func integrationRow(_ integration: Integration, _ title: String) -> SettingsRow {
        let toggle = AccentSwitch(accessibility: title) { [weak self] on in
            guard let self else { return }
            integration.preference.set(on, self.defaults)
            self.refresh()
        }
        integrationSwitches[integration] = toggle
        return SettingsRow(title, [toggle])
    }

    /// Whether the integration is read again on its own while a window is open (every minute, more often while a
    /// deployment builds); off, it is read when a repository opens and on ⌘R.
    private func refreshRow(_ integration: Integration, _ preference: Preference) -> SettingsRow {
        let title = String(localized: "Refresh automatically")
        let toggle = AccentSwitch(accessibility: title) { [weak self] on in
            guard let self else { return }
            preference.set(on, self.defaults)
            self.environment.app.preferencesDidChange(on)
        }
        toggle.setAccessibilityIdentifier("settings.refresh." + preference.rawValue)
        refreshSwitches[integration] = toggle
        return SettingsRow(
            title, [toggle],
            help: String(
                localized:
                    """
                    On, Gitā reads it again every minute while a window is open, and more often while \
                    something is running. Off, it is read when a repository opens and when you refresh with \
                    ⌘R.
                    """
            ))
    }

    // MARK: Lifecycle

    override func didAppear() {
        isShown = true
        follower.follow(environment.app.activeModel())
        if accounts.isDue(at: Date(), interval: Self.accountRecheckInterval) { loadAccounts() }
    }
    override func didDisappear() {
        isShown = false
        follower.stop()
        accounts.task?.cancel()
        accounts = accounts.stopped
        showAccounts()
    }
    /// Someone may have signed in to a CLI meanwhile.
    override func applicationDidBecomeActive() { if isShown { loadAccounts() } }

    // MARK: Refresh

    override func refresh() {
        follower.follow(environment.app.activeModel())
        let before = [githubRepositoryRow.isHidden, vercelRepositoryRow.isHidden]
        let model = environment.app.activeModel()
        let repository = model?.snapshot?.root.lastPathComponent
        let reports = model?.reports ?? []
        show(
            IntegrationsPresenter.repositoryRow(.github, repository: repository, reports: reports),
            in: githubRepositoryRow, githubRepository)
        show(
            IntegrationsPresenter.repositoryRow(.vercel, repository: repository, reports: reports),
            in: vercelRepositoryRow, vercelRepository)
        githubGroup.updateSeparators()
        vercelGroup.updateSeparators()
        refreshToggles()
        if before != [githubRepositoryRow.isHidden, vercelRepositoryRow.isHidden] { onLayoutChange?() }
    }
    private func show(_ value: IntegrationsPresenter.RepositoryRow?, in row: SettingsRow, _ status: SettingsStatus) {
        row.isHidden = value == nil
        guard let value else { return }
        row.titleLabel.stringValue = value.title
        status.set(value.value, color: IntegrationsPresenter.statusColor(value.status), tooltip: value.tooltip)
    }
    private func refreshToggles() {
        for (integration, toggle) in integrationSwitches { toggle.setOn(integration.isEnabled(defaults)) }
        for (integration, toggle) in refreshSwitches {
            toggle.setOn((integration == .github ? Preference.providerRefresh : .vercelRefresh).bool(defaults))
            toggle.isEnabled = integration.isEnabled(defaults)
        }
    }

    // MARK: Accounts

    /// The signed-in accounts of the existing CLI sessions, read-only.
    private func loadAccounts() {
        accounts.task?.cancel()
        let last = accounts.last
        let probe = environment.accounts
        let task = Task { [weak self] in
            async let github = probe.account(.github)
            async let vercel = probe.account(.vercel)
            let (githubAccount, vercelAccount) = await (github, vercel)
            guard let self, !Task.isCancelled else { return }
            self.accounts = .checked(AccountsRead(github: githubAccount, vercel: vercelAccount, at: Date()))
            self.showAccounts()
        }
        accounts = .checking(task, last: last)
        showAccounts()
    }
    private func showAccounts() {
        let last = accounts.last
        for (status, account) in [(githubAccount, last?.github), (vercelAccount, last?.vercel)] {
            let row = IntegrationsPresenter.accountRow(account, checking: accounts.isChecking)
            status.set(row.value, color: row.color, tooltip: row.tooltip)
        }
    }
}
