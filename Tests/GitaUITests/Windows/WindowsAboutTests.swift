import AppKit
import Combine
import Foundation
import Testing

@testable import GitaUI

@MainActor
private final class AboutTestUpdaterDriver: UpdaterDriver {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = false
    var lastUpdateCheckDate: Date?
    var checkCalls = 0

    func startUpdater() {}
    func checkForUpdates() { checkCalls += 1 }
    func observeChanges(_: @escaping @MainActor (UpdaterDriverSnapshot) -> Void) -> AnyCancellable { AnyCancellable {} }
}

@MainActor
@Suite("Windows about")
struct WindowsAboutTests {
    @Test func preparesTheWindowOnceUsingSharedAboutContentView() throws {
        UITestSupport.bootstrap()
        let updater = AppUpdater(activateApp: {}, presentUnavailable: {})
        let controller = AboutWindowController(
            configuration: AboutConfiguration(updater: updater, openURL: { _ in }, noticesURL: nil))
        let window = controller.prepareWindow()
        #expect(controller.prepareWindow() === window)
        #expect(window.title == String(localized: "About Gitā"))
        #expect(controller.aboutContentView != nil)
        #expect(window.contentLayoutRect.width == AboutWindowController.width)
        #expect(window.frame.height > 120)
        #expect(!window.isVisible)
        #expect(window.delegate === controller)
        if let contentView = window.contentView {
            UITestSupport.render(contentView)
        }
    }

    @Test func showsHeroLocationUpdateControlsAndHidesAcknowledgementsWhenAbsent() async throws {
        UITestSupport.bootstrap()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitaUITests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }

        let driver = AboutTestUpdaterDriver()
        let updater = AppUpdater(
            driverFactory: { _ in driver },
            officialBuildCheck: { _ in true },
            activateApp: {},
            presentUnavailable: {})
        var env = AppEnvironment(
            isDevelopment: false, defaults: .standard, arguments: [], bundle: .main,
            startsServices: true, statusBar: .system)
        env.bundleURL = URL(fileURLWithPath: "/Applications/Gita.app")
        await updater.start(environment: env)?.value

        let view = AboutContentView(
            configuration: AboutConfiguration(
                updater: updater, pasteboard: pasteboard, openURL: { _ in }, noticesURL: nil))
        view.layoutSubtreeIfNeeded()

        let texts = SetupTestSupport.views(NSTextField.self, in: view).map(\.stringValue)
        #expect(texts.contains("Gitā"))
        #expect(texts.contains("Clever Mechanisms"))
        #expect(texts.contains("\(AppInfo.version) (\(AppInfo.build))"))
        #expect(texts.contains("\(AppInfo.system) · \(AppInfo.architecture)"))
        #expect(texts.contains(AppInfo.location))

        let buttons = SetupTestSupport.views(ActionButton.self, in: view)
        #expect(!buttons.contains { $0.accessibilityIdentifier() == "about.acknowledgementsLink" })

        #expect(view.updateButton.accessibilityIdentifier() == "about.checkForUpdates")
        view.updateButton.performClick(nil)
        #expect(driver.checkCalls == 1)

        #expect(view.autoCheckToggle.isEnabled)
        view.autoCheckToggle.settingsPress()
        #expect(!updater.automaticallyChecksForUpdates)
        view.autoDownloadToggle.settingsPress()
        #expect(updater.automaticallyDownloadsUpdates)

        // When an update is available, the button switches to Install Update.
        updater.recordFoundVersion("2.0.0")
        #expect(view.updateButton.accessibilityIdentifier() == "about.installUpdate")
        #expect(view.updateButton.title == String(localized: "Install Update"))
        view.updateButton.performClick(nil)
        #expect(driver.checkCalls == 2)

        view.copyInfo.performClick(nil)
        #expect(pasteboard.string(forType: .string) == AppInfo.summary)
        #expect(view.copyInfo.title == String(localized: "Copied"))
        #expect(view.isFlipped)
    }

    @Test func statusTextFormatsAllUpdaterStates() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = now.addingTimeInterval(-300)
        let driver = AboutTestUpdaterDriver()
        let updater = AppUpdater(
            driverFactory: { _ in driver },
            officialBuildCheck: { _ in true },
            activateApp: {},
            presentUnavailable: {})
        var env = AppEnvironment(
            isDevelopment: false, defaults: .standard, arguments: [], bundle: .main,
            startsServices: true, statusBar: .system)
        env.bundleURL = URL(fileURLWithPath: "/Applications/Gita.app")
        await updater.start(environment: env)?.value

        #expect(AboutContentView.statusText(for: updater, now: now).isEmpty)

        updater.checkForUpdates()
        #expect(AboutContentView.statusText(for: updater, now: now) == String(localized: "Checking…"))

        updater.recordUpdateCycleFinished(lastCheckDate: nil, error: nil)
        #expect(AboutContentView.statusText(for: updater, now: now) == String(localized: "Up to date"))

        updater.recordUpdateCycleFinished(lastCheckDate: recent, error: nil)
        #expect(AboutContentView.statusText(for: updater, now: now).contains("5"))

        updater.checkForUpdates()
        let failure = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timeout"])
        updater.recordUpdateCycleFinished(lastCheckDate: recent, error: failure)
        #expect(AboutContentView.statusText(for: updater, now: now) == "Timeout")

        updater.recordFoundVersion("1.9.0")
        #expect(AboutContentView.statusText(for: updater, now: now) == String(localized: "Version 1.9.0 is available"))
    }

    @Test func appInfoDescribesCopyLocationTranslocationAndThirdPartyNotices() throws {
        #expect(AppInfo.summary.hasPrefix("Gitā \(AppInfo.version) (\(AppInfo.build)"))
        #expect(AppInfo.summary.contains(AppInfo.architecture))
        #expect(AppInfo.summary.hasSuffix(AppInfo.location))
        #expect(AppInfo.system.hasPrefix("macOS "))
        #expect(AppInfo.revision == nil || AppInfo.revision?.count ?? 0 <= 7)

        #expect(
            AppInfo.location(of: URL(fileURLWithPath: "/Applications/Gita.app"), home: "/Users/dev") == "/Applications")
        #expect(
            AppInfo.location(of: URL(fileURLWithPath: "/Users/dev/Applications/Gita.app"), home: "/Users/dev")
                == "~/Applications")
        #expect(AppInfo.location(of: URL(fileURLWithPath: "/Users/dev/Gita.app"), home: "/Users/dev") == "~")
        #expect(
            AppInfo.location(
                of: URL(fileURLWithPath: "/private/var/folders/ab/cd/T/AppTranslocation/1234/d/Gita.app"),
                home: "/Users/dev") == String(localized: "Temporary copy (App Translocation)"))

        #expect(AppInfo.bugReportSummary.hasSuffix(AppInfo.bugReportLocation))
        #expect(
            AppInfo.bugReportLocation(of: URL(fileURLWithPath: "/Applications/Gita.app"), home: "/Users/dev")
                == "/Applications")
        #expect(
            AppInfo.bugReportLocation(of: URL(fileURLWithPath: "/Users/dev/Applications/Gita.app"), home: "/Users/dev")
                == "~")
        #expect(
            AppInfo.bugReportLocation(of: URL(fileURLWithPath: "/Users/dev/Gita.app"), home: "/Users/dev") == "~")
        #expect(
            AppInfo.bugReportLocation(
                of: URL(fileURLWithPath: "/Volumes/PrivateSSD/Apps/Gita.app"), home: "/Users/dev") == "external volume")
        #expect(
            AppInfo.bugReportLocation(
                of: URL(fileURLWithPath: "/private/var/folders/ab/cd/T/AppTranslocation/1234/d/Gita.app"),
                home: "/Users/dev") == "App Translocation")
        #expect(
            AppInfo.bugReportLocation(of: URL(fileURLWithPath: "/opt/custom/Gita.app"), home: "/Users/dev") == "other")

        let emptyBundleDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaTestEmpty-\(UUID().uuidString).bundle", isDirectory: true)
        let populatedBundleDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaTestNotices-\(UUID().uuidString).bundle", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: emptyBundleDir)
            try? FileManager.default.removeItem(at: populatedBundleDir)
        }
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>dev.clevermechanisms.Gita.testbundle</string>
            <key>CFBundlePackageType</key><string>BNDL</string>
            </dict></plist>
            """
        for dir in [emptyBundleDir, populatedBundleDir] {
            let contents = dir.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("Resources/ThirdParty", isDirectory: true),
                withIntermediateDirectories: true)
            try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        }
        let noticesFile =
            populatedBundleDir
            .appendingPathComponent("Contents/Resources/ThirdParty/ThirdParty-Notices.txt")
        try "Notices".write(to: noticesFile, atomically: true, encoding: .utf8)

        let emptyBundle = try #require(Bundle(url: emptyBundleDir))
        let populatedBundle = try #require(Bundle(url: populatedBundleDir))
        #expect(AppInfo.thirdPartyNoticesURL(in: emptyBundle) == nil)
        #expect(AppInfo.thirdPartyNoticesURL(in: populatedBundle)?.lastPathComponent == "ThirdParty-Notices.txt")
    }
}
