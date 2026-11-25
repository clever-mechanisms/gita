import AppKit
import Foundation
import Testing

@testable import GitaUI

@Suite("Settings About pane and notification sources") @MainActor
struct SettingsAboutPaneTests {
    @Test func aboutCopiesVersionInfoOpensLinksAndBindsUpdater() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let notices = FileManager.default.temporaryDirectory.appendingPathComponent("ThirdParty-Notices.txt")
        let updater = AppUpdater(activateApp: {}, presentUnavailable: {})
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("gita.tests.about." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }

        let configuration = AboutConfiguration(updater: updater, pasteboard: pasteboard, noticesURL: notices)
        let pane = AboutSettingsPane(environment: recorder.environment, configuration: configuration)
        pane.didAppear()
        pane.refresh()

        pane.contentView.copyInfo.performClick(nil)
        #expect(pasteboard.string(forType: .string) == AppInfo.summary)
        #expect(pane.contentView.copyInfo.title == String(localized: "Copied"))

        #expect(pane.view.settingsDescendants(of: SettingsHelpButton.self).isEmpty)
        let labels = pane.view.settingsDescendants(of: NSTextField.self).map(\.stringValue)
        #expect(labels.contains("Gitā"))
        #expect(labels.contains("Clever Mechanisms"))
        #expect(labels.contains(AppInfo.location))
        #expect(labels.filter { $0 == String(localized: "File a bug report") }.count == 1)

        // Links group exposes Website, Release Notes, Support, GitHub, Report Bug, and Acknowledgements.
        for (id, title, prefix) in [
            ("about.websiteLink", String(localized: "Website"), "https://getgita.app/"),
            ("about.releaseNotesLink", String(localized: "Release Notes"), "https://getgita.app/changelog?"),
            ("about.supportLink", String(localized: "Support"), "https://getgita.app/support?"),
            ("about.repositoryLink", "GitHub", "https://github.com/clever-mechanisms/gita"),
            ("about.issuesLink", String(localized: "Report Bug"), BugReport.issues + "?body="),
            ("about.acknowledgementsLink", String(localized: "Acknowledgements"), notices.absoluteString),
        ] {
            let button = try #require(
                pane.view.settingsDescendants(of: ActionButton.self).first {
                    $0.accessibilityIdentifier() == id
                }, "Missing button \(id)")
            #expect(button.title == title)
            #expect(button.image != nil)
            if id == "about.repositoryLink" {
                #expect(button.image?.accessibilityDescription == "GitHub")
            }
            button.performClick(nil)
            let opened = try #require(recorder.openedURLs.last)
            #expect(opened.absoluteString.hasPrefix(prefix))
            if id == "about.issuesLink" {
                let body = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
                #expect(body?.hasSuffix(AppInfo.bugReportSummary) == true)
            }
        }
    }

    @Test func eventsOfAnIntegrationThatIsOffAreGreyedOut() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        Preference.registerDefaults(in: recorder.defaults)
        recorder.defaults.set(true, forKey: Preference.notifications.rawValue)
        recorder.defaults.set(false, forKey: Preference.useVercel.rawValue)
        recorder.defaults.set(false, forKey: Integration.agents.preference.rawValue)
        let pane = NotificationSettingsPane(environment: recorder.environment)
        pane.refresh()
        let vercelEvents: Set<Preference> = [.notifyPreviewReady, .notifyProductionDeployed, .notifyVercelAlert]
        let agentEvents: Set<Preference> = [.notifyAgentNeedsInput, .notifyAgentFinished]
        for (preference, toggle) in pane.categories {
            #expect(toggle.isEnabled == !vercelEvents.union(agentEvents).contains(preference))
        }
        func notes(_ text: String) -> Int {
            pane.view.settingsDescendants(of: NSTextField.self).filter { $0.stringValue == text }.count
        }
        #expect(notes(NotificationSettingsPane.offNote(.vercel)) == vercelEvents.count)
        #expect(notes(NotificationSettingsPane.offNote(.agents)) == agentEvents.count)
        #expect(NotificationSettingsPane.offNote(.agents) != NotificationSettingsPane.offNote(.github))
        // One "?" per event, and one for the test button.
        #expect(pane.view.settingsDescendants(of: SettingsHelpButton.self).count == pane.categories.count + 1)
    }
}
