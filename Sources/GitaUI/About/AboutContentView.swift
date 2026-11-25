import AppKit

/// Injectable dependencies for `AboutContentView` so both Settings and the About window share one configuration.
@MainActor
struct AboutConfiguration {
    var updater: AppUpdater = .shared
    var pasteboard: NSPasteboard = .general
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var noticesURL: URL? = AppInfo.thirdPartyNoticesURL()
}

/// Shared AppKit About content rendered by both `AboutSettingsPane` (Settings ▸ About) and `AboutWindowController`
/// (App menu ▸ About Gitā). Single source of truth with zero duplicated layout code.
@MainActor
final class AboutContentView: NSView {
    private static let linkSymbolSize: CGFloat = 14

    private let stack = NSStackView()
    private let updater: AppUpdater
    private let openURL: (URL) -> Void
    private let noticesURL: URL?
    private var observerID: UUID?
    private var copyReset: Task<Void, Never>?

    /// Where Copy Version Info writes; tests pass a private pasteboard.
    var pasteboard: NSPasteboard

    private(set) lazy var copyInfo = SettingsForm.button(
        String(localized: "Copy Version Info"), symbol: "doc.on.doc"
    ) { [weak self] in self?.copyVersionInfo() }

    private let updateStatusNote = SettingsForm.note()
    private(set) lazy var updateButton = SettingsForm.button(
        String(localized: "Check for Updates…"), symbol: "arrow.clockwise"
    ) { [weak self] in self?.performUpdateAction() }

    private(set) lazy var autoCheckToggle = AccentSwitch(
        accessibility: String(localized: "Check automatically")
    ) { [weak self] on in
        self?.updater.automaticallyChecksForUpdates = on
    }

    private(set) lazy var autoDownloadToggle = AccentSwitch(
        accessibility: String(localized: "Download updates automatically")
    ) { [weak self] on in
        self?.updater.automaticallyDownloadsUpdates = on
    }

    init(configuration: AboutConfiguration = AboutConfiguration()) {
        updater = configuration.updater
        pasteboard = configuration.pasteboard
        openURL = configuration.openURL
        noticesURL = configuration.noticesURL
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        observerID = updater.observe { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable, message: "AboutContentView is built in code")
    required init?(coder _: NSCoder) { fatalError("AboutContentView is built in code") }

    isolated deinit {
        copyReset?.cancel()
        if let observerID { updater.removeObserver(observerID) }
    }

    override var isFlipped: Bool { true }

    func refresh() {
        let pending = updater.availableVersion ?? updater.pendingVersion
        updateStatusNote.stringValue = Self.statusText(for: updater)
        if pending != nil {
            updateButton.title = String(localized: "Install Update")
            updateButton.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            updateButton.setAccessibilityIdentifier("about.installUpdate")
            updateButton.isEnabled = true
        } else {
            updateButton.title = String(localized: "Check for Updates…")
            updateButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            updateButton.setAccessibilityIdentifier("about.checkForUpdates")
            updateButton.isEnabled = !updater.isEnabled || updater.canCheckForUpdates
        }
        autoCheckToggle.setOn(updater.automaticallyChecksForUpdates)
        autoCheckToggle.isEnabled = updater.isEnabled
        autoDownloadToggle.setOn(updater.automaticallyDownloadsUpdates)
        autoDownloadToggle.isEnabled = updater.isEnabled
    }

    func copyVersionInfo() {
        pasteboard.clearContents()
        pasteboard.setString(AppInfo.summary, forType: .string)
        copyInfo.title = String(localized: "Copied")
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copyInfo.title = String(localized: "Copy Version Info")
        }
    }

    static func statusText(for updater: AppUpdater, now: Date = Date()) -> String {
        if let version = updater.availableVersion ?? updater.pendingVersion {
            return String(localized: "Version \(version) is available")
        }
        switch updater.state {
        case .checking:
            return String(localized: "Checking…")
        case .upToDate:
            return lastCheckedText(updater.lastUpdateCheckDate, now: now) ?? String(localized: "Up to date")
        case .available(let version):
            return String(localized: "Version \(version) is available")
        case .failed(let message):
            return message
        case .idle:
            return lastCheckedText(updater.lastUpdateCheckDate, now: now) ?? ""
        }
    }

    private static func lastCheckedText(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: now)
        return String(localized: "Checked \(relative)")
    }

    private func build() {
        copyInfo.setAccessibilityIdentifier("about.copyVersionInfo")
        autoCheckToggle.setAccessibilityIdentifier("about.autoCheckUpdates")
        autoDownloadToggle.setAccessibilityIdentifier("about.autoDownloadUpdates")

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        var sections: [NSView] = [makeHero(), makeUpdatesGroup(), makeThisCopyGroup()]
        if let links = makeLinksGroup() { sections.append(links) }
        for section in sections {
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeHero() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])
        let name = SettingsForm.label("Gitā", font: TextLines.system(22, weight: .bold))
        let publisher = SettingsForm.label("Clever Mechanisms", color: Theme.secondaryText, font: Theme.body)
        let version = SettingsForm.label(
            String(localized: "Version \(AppInfo.version) (\(AppInfo.build))"), color: Theme.secondaryText)
        version.isSelectable = true
        let tagline = NSTextField(
            wrappingLabelWithString: String(localized: "Your repositories, CI, deployments and agents in one window."))
        tagline.font = Theme.body
        tagline.textColor = Theme.text
        let texts = NSStackView(views: [name, publisher, version, tagline])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let hero = NSStackView(views: [icon, texts])
        hero.alignment = .centerY
        hero.spacing = 14
        return hero
    }

    private func makeUpdatesGroup() -> SettingsGroup {
        let rows = [
            SettingsRow(String(localized: "Software updates"), [updateStatusNote, updateButton]),
            SettingsRow(String(localized: "Check automatically"), [autoCheckToggle]),
            SettingsRow(String(localized: "Download updates automatically"), [autoDownloadToggle]),
        ]
        return SettingsGroup(String(localized: "Updates"), rows)
    }

    private func makeThisCopyGroup() -> SettingsGroup {
        var rows = [
            SettingsRow(String(localized: "Version"), [value("\(AppInfo.version) (\(AppInfo.build))")]),
            SettingsRow(String(localized: "System"), [value("\(AppInfo.system) · \(AppInfo.architecture)")]),
            SettingsRow(String(localized: "Location"), [value(AppInfo.location)]),
            SettingsRow(String(localized: "License"), [value("MIT · © 2026 Clever Mechanisms")]),
            SettingsRow(String(localized: "Version info"), [copyInfo]),
        ]
        if let revision = AppInfo.revision {
            rows.insert(SettingsRow(String(localized: "Source"), [value(revision)]), at: 1)
        }
        return SettingsGroup(String(localized: "This copy"), rows)
    }

    private func makeLinksGroup() -> SettingsGroup? {
        let rows = linkItems().compactMap(makeLinkRow)
        return rows.isEmpty ? nil : SettingsGroup(String(localized: "Links"), rows)
    }

    private struct LinkItem {
        var title: String
        var actionTitle: String
        var image: NSImage?
        var id: String
        var url: URL?
    }

    private func linkItems() -> [LinkItem] {
        let symbol: (String) -> NSImage? = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        var items: [LinkItem] = [
            LinkItem(
                title: Website.host ?? "", actionTitle: String(localized: "Website"), image: symbol("globe"),
                id: "about.websiteLink", url: Website.home),
            LinkItem(
                title: String(localized: "Release Notes"), actionTitle: String(localized: "Release Notes"),
                image: symbol("doc.text"), id: "about.releaseNotesLink", url: Website.changelog),
            LinkItem(
                title: String(localized: "Support"), actionTitle: String(localized: "Support"),
                image: symbol("questionmark.bubble"), id: "about.supportLink", url: Website.support),
            LinkItem(
                title: Website.repositoryPath, actionTitle: "GitHub",
                image: BrandMarks.image(.github, size: Self.linkSymbolSize),
                id: "about.repositoryLink", url: Website.repository),
            LinkItem(
                title: String(localized: "File a bug report"), actionTitle: String(localized: "Report Bug"),
                image: symbol("ladybug"), id: "about.issuesLink", url: BugReport.url()),
        ]
        if let noticesURL {
            items.append(
                LinkItem(
                    title: String(localized: "Open-source notices"),
                    actionTitle: String(localized: "Acknowledgements"),
                    image: symbol("doc.plaintext"), id: "about.acknowledgementsLink", url: noticesURL))
        }
        return items
    }

    private func makeLinkRow(_ item: LinkItem) -> SettingsRow? {
        guard let url = item.url else { return nil }
        let button = SettingsForm.button(item.actionTitle, image: item.image) { [weak self] in
            self?.openURL(url)
        }
        button.setAccessibilityIdentifier(item.id)
        button.toolTip = url.absoluteString
        return SettingsRow(item.title, [button])
    }

    private func value(_ text: String) -> NSTextField {
        let field = SettingsForm.note(text)
        field.isSelectable = true
        return field
    }

    private func performUpdateAction() {
        if updater.availableVersion != nil || updater.pendingVersion != nil {
            updater.installAvailableUpdate()
        } else {
            updater.checkForUpdates()
        }
    }
}
