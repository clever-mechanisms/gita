import AppKit

/// Settings ▸ About: the app, this copy's version and system, a bug report (a new GitHub issue, and the version line to
/// paste into it), the product's links when it has a website, and its licenses.
@MainActor
final class AboutSettingsPane: SettingsPaneContent {
    /// Where Copy Version Info writes; tests pass a private pasteboard.
    var pasteboard = NSPasteboard.general
    private(set) lazy var copyInfo = SettingsForm.button(String(localized: "Copy Version Info"), symbol: "doc.on.doc") {
        [weak self] in self?.copyVersionInfo()
    }
    private var copyReset: Task<Void, Never>?

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        copyInfo.setAccessibilityIdentifier("settings.copyVersionInfo")
        var groups: [NSView] = [header(), thisCopy()]
        if let links = links() { groups.append(links) }
        groups.append(openSource())
        setGroups(groups)
    }
    isolated deinit { copyReset?.cancel() }

    private func header() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64),
        ])
        let name = SettingsForm.label("Gitā", font: TextLines.system(22, weight: .bold))
        let version = SettingsForm.label(
            String(localized: "Version \(AppInfo.version) (\(AppInfo.build))"), color: Theme.secondaryText)
        let tagline = NSTextField(
            wrappingLabelWithString: String(localized: "Your repositories, CI, deployments and agents in one window."))
        tagline.font = Theme.body
        tagline.textColor = Theme.text
        let texts = NSStackView(views: [name, version, tagline])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        let header = NSStackView(views: [icon, texts])
        header.alignment = .centerY
        header.spacing = 14
        return header
    }

    private func thisCopy() -> SettingsGroup {
        var rows = [
            SettingsRow(String(localized: "Version"), [value("\(AppInfo.version) (\(AppInfo.build))")]),
            SettingsRow(String(localized: "System"), [value("\(AppInfo.system) · \(AppInfo.architecture)")]),
        ]
        if let revision = AppInfo.revision {
            rows.insert(SettingsRow(String(localized: "Source"), [value(revision)]), at: 1)
        }
        rows.append(SettingsRow(String(localized: "Version info"), [copyInfo]))
        return SettingsGroup(String(localized: "This copy"), rows)
    }

    /// Website, GitHub repository and bug report links.
    private func links() -> SettingsGroup? {
        struct LinkRow {
            var title: String
            var actionTitle: String
            var image: NSImage?
            var id: String
            var url: URL?
        }
        let symbol: (String) -> NSImage? = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        let links: [LinkRow] = [
            LinkRow(
                title: Website.host ?? "", actionTitle: String(localized: "Website"), image: symbol("globe"),
                id: "settings.websiteLink", url: Website.home),
            LinkRow(
                title: Website.repositoryPath, actionTitle: "GitHub",
                image: BrandMarks.image(.github, size: SettingsForm.markSize),
                id: "settings.repositoryLink", url: Website.repository),
            LinkRow(
                title: String(localized: "File a bug report"), actionTitle: String(localized: "Report Bug"),
                image: symbol("ladybug"), id: "settings.issuesLink", url: BugReport.url()),
        ]
        let rows = links.compactMap { item in
            item.url.map { url in
                let button = SettingsForm.button(item.actionTitle, image: item.image) { [weak self] in
                    self?.environment.system.openURL(url)
                }
                button.setAccessibilityIdentifier(item.id)
                button.toolTip = url.absoluteString
                return SettingsRow(item.title, [button])
            }
        }
        return rows.isEmpty ? nil : SettingsGroup(String(localized: "Links"), rows)
    }

    private func openSource() -> SettingsGroup {
        let licenses = SettingsForm.button(String(localized: "Show Licenses"), symbol: "folder") { [weak self] in
            if let resources = Bundle.main.resourceURL { self?.environment.system.openURL(resources) }
        }
        licenses.setAccessibilityIdentifier("settings.showLicenses")
        return SettingsGroup(
            String(localized: "Open source"),
            [
                SettingsRow(String(localized: "License"), [value("MIT · © 2026 Clever Mechanisms")]),
                SettingsRow(String(localized: "Bundled fonts, logos and review skills"), [licenses]),
            ])
    }

    private func value(_ text: String) -> NSTextField {
        let field = SettingsForm.note(text)
        field.isSelectable = true
        return field
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
}
