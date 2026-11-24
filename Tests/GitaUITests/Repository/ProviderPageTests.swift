import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Provider page GitHub account visibility") @MainActor
struct ProviderPageTests {
    private static let rolottr = GitHubLogin("rolottr")
    private static let work = GitHubLogin("work")

    private func popUp(in page: ProviderPageView) -> NSPopUpButton? {
        page.settingsDescendants(of: NSPopUpButton.self).first {
            $0.accessibilityIdentifier() == "provider.accountPopUp"
        }
    }

    @Test func alwaysShowsAccountPickerOnGitHubPagesEvenWithZeroOrOneAccount() throws {
        let page = ProviderPageView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let one = try #require(Self.rolottr)
        let singlePicker = GitHubAccountPicker(logins: [one], choice: nil, viewer: nil)
        let prState = ProviderPageState(section: .pullRequests, signals: [], reports: [], accounts: singlePicker)
        page.update(prState, vercel: nil)

        let popup = try #require(popUp(in: page))
        #expect(!popup.isHidden)
        #expect(popup.itemTitles.contains(String(localized: "Automatic (\("rolottr"))")))
        #expect(popup.itemTitles.contains("rolottr"))
        #expect(popup.itemTitles.contains(String(localized: "Add account…")))

        // Zero signed-in accounts still shows status + Add account… on Workflows.
        let zeroPicker = GitHubAccountPicker(logins: [], choice: nil, viewer: nil)
        let wfState = ProviderPageState(section: .workflows, signals: [], reports: [], accounts: zeroPicker)
        page.update(wfState, vercel: nil)
        #expect(!popup.isHidden)
        #expect(popup.itemTitles.first == String(localized: "No signed-in account"))
        #expect(popup.itemTitles.contains(String(localized: "Add account…")))

        // Deployments (Vercel) hides the GitHub account picker.
        let deployState = ProviderPageState(section: .deployments, signals: [], reports: [], accounts: singlePicker)
        #expect(deployState.accounts == nil)
        page.update(deployState, vercel: nil)
        #expect(popup.isHidden)
    }

    @Test func choosingAccountAndAddAccountTriggerCallbacksAndRefreshOnReturn() throws {
        let page = ProviderPageView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let one = try #require(Self.rolottr)
        let two = try #require(Self.work)
        var chosen: [GitHubLogin?] = []
        var added = 0
        var refreshed = 0
        page.onChooseAccount = { chosen.append($0) }
        page.onAddAccount = { added += 1 }
        page.onRefresh = { refreshed += 1 }

        let picker = GitHubAccountPicker(logins: [one, two], choice: .automatic(one), viewer: "rolottr")
        page.update(ProviderPageState(section: .pullRequests, signals: [], reports: [], accounts: picker), vercel: nil)

        let popup = try #require(popUp(in: page))
        popup.selectItem(withTitle: "work")
        popup.sendAction(popup.action, to: popup.target)
        #expect(chosen == [two])

        // Picking "Add account…" restores previous selection, opens login flow, and refreshes when app returns.
        popup.selectItem(withTag: ProviderPageView.addAccountTag)
        popup.sendAction(popup.action, to: popup.target)
        #expect(added == 1)
        #expect(popup.indexOfSelectedItem == 0)

        page.handleAppDidBecomeActive()
        #expect(refreshed == 1)
        // Only one refresh per add-account return.
        page.handleAppDidBecomeActive()
        #expect(refreshed == 1)
    }

    @Test func loginScriptWritesExecutableGhAuthLoginCommand() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaProviderPageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try TerminalScriptLauncher.writeScript(GitHubAccountLogin.scriptText, in: folder)
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("exec gh auth login --hostname github.com"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let mode = attributes[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func openTerminalLaunchesTerminalOrGhosttyAndHandlesMissingFolderOrApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaOpenTerminalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "GitaUITests.OpenTerminal.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let ghostty = root.appendingPathComponent("Ghostty.app", isDirectory: true)
        let contents = ghostty.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.mitchellh.ghostty</string>
            </dict></plist>
            """
        try Data(plist.utf8).write(to: contents.appendingPathComponent("Info.plist"))

        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        var openedDocs: [([URL], URL)] = []
        var openedApps: [(URL, [String])] = []
        var builtInScript: URL?
        let opener = AppOpener(
            locate: { id in
                if id == "com.mitchellh.ghostty" { return ghostty }
                if id == OpenIn.defaultTerminal { return terminalURL }
                return nil
            },
            open: { docs, app, _ in openedDocs.append((docs, app)) },
            openApplication: { app, config in openedApps.append((app, config.arguments)) },
            reveal: { _ in },
            openBuiltInTerminal: { _, script in builtInScript = script })

        let scriptsFolder = root.appendingPathComponent("scripts", isDirectory: true)
        // Default Terminal opens the .command document.
        GitHubAccountLogin.openTerminal(opener: opener, defaults: defaults, folder: scriptsFolder)
        #expect(openedDocs.count == 1)
        #expect(openedDocs.first?.1 == terminalURL)

        defaults.set(OpenIn.builtInTerminal, forKey: Preference.terminalBundleID.rawValue)
        GitHubAccountLogin.openTerminal(opener: opener, defaults: defaults, folder: scriptsFolder)
        let login = try #require(builtInScript)
        #expect(ReviewScripts.isOwn(login, in: scriptsFolder))
        #expect(try String(contentsOf: login, encoding: .utf8) == GitHubAccountLogin.scriptText)

        // Ghostty receives command-line arguments to run the script.
        defaults.set("com.mitchellh.ghostty", forKey: Preference.terminalBundleID.rawValue)
        GitHubAccountLogin.openTerminal(opener: opener, defaults: defaults, folder: scriptsFolder)
        #expect(openedApps.count == 1)
        #expect(openedApps.first?.0 == ghostty)
        #expect(openedApps.first?.1.first == "-e")

        // Missing terminal app and unwritable script folder both fail gracefully.
        let missingOpener = AppOpener(
            locate: { _ in nil }, open: { _, _, _ in }, openApplication: { _, _ in },
            reveal: { _ in }, openBuiltInTerminal: { _, _ in })
        GitHubAccountLogin.openTerminal(opener: missingOpener, defaults: defaults, folder: scriptsFolder)
        let blockerFile = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blockerFile)
        GitHubAccountLogin.openTerminal(opener: opener, defaults: defaults, folder: blockerFile)
    }
}
