import AppKit
import GitaCore

/// Settings ▸ Integrations: GitHub (including every signed-in/expired `gh` account and its per-repository assignments)
/// and Vercel, each switchable, refreshing on its own or not, with its account and the active repository's status.
@MainActor
final class IntegrationsSettingsPane: SettingsPaneContent {
    private static let accountRecheckInterval: TimeInterval = 60

    private(set) var integrationSwitches: [Integration: AccentSwitch] = [:]
    private(set) var refreshSwitches: [Integration: AccentSwitch] = [:]
    let githubAccount = SettingsStatus()
    let githubRepository = SettingsStatus()
    private(set) lazy var githubRepositoryRow = SettingsRow("", [githubRepository])
    private(set) lazy var addGitHubAccountButton: ActionButton = {
        let button = SettingsForm.button(String(localized: "Add account…"), symbol: "plus") { [weak self] in
            self?.triggerAddGitHubAccount()
        }
        button.setAccessibilityIdentifier("settings.github.addAccount")
        return button
    }()
    private lazy var githubGroup = SettingsGroup(
        "GitHub",
        [
            integrationRow(.github, String(localized: "Pull requests, workflows and checks")),
            refreshRow(.github, .providerRefresh),
            SettingsRow(String(localized: "Account"), [addGitHubAccountButton, githubAccount]),
            githubRepositoryRow,
        ])
    private(set) lazy var githubAccountsGroup = SettingsGroup(String(localized: "GitHub Accounts"), [])
    private(set) var accountAssignmentControls: [String: (popup: ActionPopUpButton, reset: ActionButton)] = [:]

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

    struct AccountsRead {
        var github: CLIAccountProbe.Account
        var vercel: CLIAccountProbe.Account
        var at: Date
        var githubAccounts: [GitHubAccount] = []
    }

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
        func isDue(at now: Date, interval: TimeInterval) -> Bool {
            last.map { now.timeIntervalSince($0.at) > interval } ?? true
        }
        var stopped: Self {
            guard case .checking(_, let last) = self else { return self }
            return last.map(Self.checked) ?? .unchecked
        }
        var task: Task<Void, Never>? { if case .checking(let task, _) = self { task } else { nil } }
    }

    private(set) var accounts = AccountsCheck.unchecked
    private var isShown = false
    private var preferenceObserver: NSObjectProtocol?

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        showAccounts()
        SettingsForm.mark(githubGroup.titleLabel, BrandMarks.image(.github, size: SettingsForm.markSize), "GitHub")
        SettingsForm.mark(vercelGroup.titleLabel, BrandMarks.image(.vercel, size: SettingsForm.markSize), "Vercel")
        setGroups([githubGroup, githubAccountsGroup, vercelGroup])
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .gitaPreferenceChanged, object: nil, queue: .main
        ) { [weak self] note in
            let preference = Preference(changed: note)
            MainActor.assumeIsolated {
                guard preference == .githubAccounts else { return }
                self?.rebuildGitHubAccounts()
            }
        }
    }
    isolated deinit {
        accounts.task?.cancel()
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    }

    private func integrationRow(_ integration: Integration, _ title: String) -> SettingsRow {
        let toggle = AccentSwitch(accessibility: title) { [weak self] on in
            guard let self else { return }
            integration.preference.set(on, self.defaults)
            self.refresh()
        }
        integrationSwitches[integration] = toggle
        return SettingsRow(title, [toggle])
    }

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
        rebuildGitHubAccounts()
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
            async let github = probe.githubStatus()
            async let vercel = probe.account(.vercel)
            let (githubRead, vercelAccount) = await (github, vercel)
            guard let self, !Task.isCancelled else { return }
            self.accounts = .checked(
                AccountsRead(
                    github: githubRead.account, vercel: vercelAccount, at: Date(),
                    githubAccounts: githubRead.accounts))
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
        rebuildGitHubAccounts()
    }

    func rebuildGitHubAccounts() {
        let beforeSignature = githubAccountsGroup.rows.map {
            $0.titleLabel.stringValue + "\0" + ($0.subtitleLabel?.stringValue ?? "")
        }
        accountAssignmentControls.removeAll()
        let store = GitHubAccountStore(defaults: defaults)
        let assignments = store.allAssignments()
        let listed = accounts.last?.githubAccounts ?? []
        let signedInAccounts = listed.filter(\.isSignedIn).map(\.id).sorted()
        var rows: [SettingsRow] = []

        if accounts.last == nil && accounts.isChecking && assignments.isEmpty {
            rows.append(SettingsRow(String(localized: "Checking GitHub accounts…"), []))
        } else {
            let (sections, orphaned) = IntegrationsPresenter.githubSections(
                accounts: listed, assignments: assignments)
            for section in sections {
                rows.append(accountRow(for: section))
                for repo in section.repositories {
                    rows.append(assignmentRow(for: repo, signedInAccounts: signedInAccounts, missingAccount: nil))
                }
            }
            for repo in orphaned {
                rows.append(
                    assignmentRow(
                        for: repo, signedInAccounts: signedInAccounts, missingAccount: repo.choice.accountID))
            }
            if rows.isEmpty {
                let add = SettingsForm.button(String(localized: "Add account…"), symbol: "plus") { [weak self] in
                    self?.triggerAddGitHubAccount()
                }
                rows.append(SettingsRow(String(localized: "No signed-in GitHub accounts"), [add]))
            }
        }
        githubAccountsGroup.setRows(rows)
        let afterSignature = rows.map {
            $0.titleLabel.stringValue + "\0" + ($0.subtitleLabel?.stringValue ?? "")
        }
        if beforeSignature != afterSignature { onLayoutChange?() }
    }

    private func accountRow(for section: IntegrationsPresenter.AccountSection) -> SettingsRow {
        let status = SettingsStatus()
        status.set(section.statusText, color: section.statusColor, tooltip: section.tooltip)
        var accessories: [NSView] = [status]
        if !section.account.isSignedIn {
            let profile = section.account.profile
            let signIn = SettingsForm.button(String(localized: "Sign in…"), symbol: "person.badge.key") { [weak self] in
                self?.triggerAddGitHubAccount(profile: profile)
            }
            accessories.append(signIn)
        }
        let row = SettingsRow(section.title, accessories, subtitle: section.subtitle)
        let key = GitHubAccountStore.accountKey(for: section.account.id)
        row.setAccessibilityIdentifier("settings.github.account." + key)
        return row
    }

    private func assignmentRow(
        for repo: IntegrationsPresenter.RepositoryAssignment, signedInAccounts: [GitHubAccountID],
        missingAccount: GitHubAccountID?
    ) -> SettingsRow {
        let popup = ActionPopUpButton { [weak self] control in
            let account = control.selectedValue.flatMap { $0.isEmpty ? nil : GitHubAccountStore.accountID(from: $0) }
            self?.changeAssignment(sourceID: repo.sourceID, account: account)
        }
        popup.controlSize = .small
        popup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        popup.setAccessibilityLabel(String(localized: "Account for \(repo.displayName)"))
        popup.setAccessibilityIdentifier("settings.github.assignment." + repo.sourceID)
        popup.addItem(String(localized: "Automatic"), value: "")
        let allForLabels = signedInAccounts + [missingAccount].compactMap { $0 }
        for account in signedInAccounts {
            let title = GitHubAccountPicker.displayTitle(for: account, among: allForLabels)
            popup.addItem(title, value: GitHubAccountStore.accountKey(for: account))
        }
        if repo.isChosen {
            let key = GitHubAccountStore.accountKey(for: repo.choice.accountID)
            if !popup.select(value: key) {
                let label = GitHubAccountPicker.displayTitle(for: repo.choice.accountID, among: allForLabels)
                popup.addItem(String(localized: "\(label) (signed out)"), value: key)
                popup.select(value: key)
            }
        } else {
            popup.selectItem(at: 0)
        }
        let reset = SettingsForm.button(String(localized: "Reset"), symbol: "arrow.counterclockwise") { [weak self] in
            self?.resetAssignment(sourceID: repo.sourceID)
        }
        reset.controlSize = .small
        reset.setAccessibilityLabel(String(localized: "Reset account for \(repo.displayName)"))
        reset.setAccessibilityIdentifier("settings.github.reset." + repo.sourceID)
        accountAssignmentControls[repo.sourceID] = (popup, reset)

        let subtitle: String =
            if let missingAccount {
                String(
                    localized:
                        "Assigned to \(GitHubAccountPicker.displayTitle(for: missingAccount, among: allForLabels)) (not signed in)"
                )
            } else if repo.isChosen {
                String(localized: "Chosen for this repository")
            } else {
                String(localized: "Detected automatically")
            }
        let row = SettingsRow(repo.displayName, [popup, reset], subtitle: subtitle)
        row.titleLabel.toolTip = repo.sourceID
        return row
    }

    private func changeAssignment(sourceID: String, account: GitHubAccountID?) {
        GitHubAccountStore(defaults: defaults).choose(account, sourceID: sourceID)
        environment.app.activeModel()?.gitHubAccountAssignmentChanged(for: sourceID)
        rebuildGitHubAccounts()
    }

    private func resetAssignment(sourceID: String) {
        GitHubAccountStore(defaults: defaults).reset(sourceID: sourceID)
        environment.app.activeModel()?.gitHubAccountAssignmentChanged(for: sourceID)
        rebuildGitHubAccounts()
    }

    private func triggerAddGitHubAccount(profile: GitHubConfigProfile? = nil) {
        environment.system.addGitHubAccount(profile)
    }
}
