import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Settings account probe")
struct SettingsAccountProbeTests {
    private func account(_ answer: Result<CommandResult, CommandError>?) async -> CLIAccountProbe.Account {
        let runs = SettingsRunLog()
        if let answer { runs.answer("gh", with: answer) }
        return await CLIAccountProbe(run: runs.runner).account(.github)
    }

    @Test func readsTheLoginOrExplainsWhyNot() async {
        let status = #"{"hosts":{"github.com":[{"login":"octo-cat_1","active":true,"state":"success"}]}}"#
        let login = await account(.success(SettingsRunLog.output(status)))
        #expect(login == .init(value: "octo-cat_1", status: .connected))
        #expect(CLIAccountProbe.Service.github.arguments == GitHubAccounts.arguments)
        let missing = await account(nil)
        #expect(missing == .init(value: String(localized: "Not installed"), status: .idle))
        let slow = await account(.failure(.timedOut))
        #expect(slow == .init(value: String(localized: "Timed out"), status: .failed))
        let broken = await account(.failure(.launchFailed(1)))
        #expect(broken == .init(value: String(localized: "Unavailable"), status: .failed))
    }

    @Test func parseTellsSignInFromFailure() {
        let signIn = CLIAccountProbe.parse(
            SettingsRunLog.output("", stderr: "To get started, run: gh AUTH login", exit: 4), label: "GitHub")
        #expect(signIn.status == .attention)
        #expect(signIn.tooltip == String(localized: "Sign in using the \("GitHub") CLI in Terminal."))
        let odd = CLIAccountProbe.parse(SettingsRunLog.output("not a login!\n"), label: "Vercel")
        #expect(odd.status == .failed)
        let failed = CLIAccountProbe.parse(SettingsRunLog.output("someone", exit: 1), label: "Vercel")
        #expect(failed.status == .failed)
        #expect(!CLIAccountProbe.isPlausibleLogin(""))
        #expect(!CLIAccountProbe.isPlausibleLogin(String(repeating: "a", count: 65)))
        #expect(CLIAccountProbe.isPlausibleLogin("team.name"))
        #expect(CLIAccountProbe.Service.vercel.arguments == ["whoami"])
    }
}

@Suite("Settings form kit") @MainActor
struct SettingsFormTests {
    @Test func accentSwitchTogglesByClickKeyAndAccessibility() throws {
        UITestSupport.bootstrap()
        var changes: [Bool] = []
        let toggle = AccentSwitch(accessibility: "Thing") { changes.append($0) }
        toggle.settingsPress()
        #expect(toggle.isOn)
        #expect(toggle.accessibilityValue() as? Int == 1)
        let space = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        toggle.keyDown(with: space)
        let mouse = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        toggle.mouseDown(with: mouse)
        #expect(changes == [true, false, true])
        #expect(toggle.acceptsFirstMouse(for: nil))
        #expect(toggle.acceptsFirstResponder)
        #expect(toggle.focusRingMaskBounds == toggle.bounds)

        toggle.isEnabled = false
        toggle.settingsPress()
        #expect(changes.count == 3)
        #expect(!toggle.acceptsFirstResponder)
        #expect(!toggle.canBecomeKeyView)
        #expect(AccentSwitch.defaultAnimation(forKey: "knobPosition") is CABasicAnimation)
        _ = AccentSwitch.defaultAnimation(forKey: "frameOrigin")
    }

    @Test func formPiecesDraw() throws {
        UITestSupport.bootstrap()
        let toggle = AccentSwitch(accessibility: "Thing") { _ in }
        toggle.setOn(true)
        let status = SettingsStatus()
        status.set("Connected", color: Theme.success, tooltip: "tip")
        #expect(!status.isHidden && status.toolTip == "tip")
        let row = SettingsRow("Row", [status, toggle])
        let second = SettingsRow("Second", [SettingsForm.note("note")])
        let group = SettingsGroup("Group", [row, second])
        #expect(!row.showsSeparator && second.showsSeparator)
        let untitled = SettingsGroup(nil, [])
        untitled.updateSeparators()
        #expect(untitled.isHidden)
        #expect(untitled.titleLabel == nil)

        let container = SettingsBackgroundView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        container.addSubview(group)
        NSLayoutConstraint.activate([
            group.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            group.topAnchor.constraint(equalTo: container.topAnchor),
            group.widthAnchor.constraint(equalToConstant: 400),
        ])
        container.layoutSubtreeIfNeeded()
        UITestSupport.render(container)
        toggle.isEnabled = false
        UITestSupport.render(toggle)
        #expect(container.isFlipped && !row.isFlipped)

        row.isHidden = true
        group.updateSeparators()
        #expect(!second.showsSeparator)
        status.set("", color: nil)
        #expect(status.isHidden)

        let label = SettingsForm.label("GitHub")
        SettingsForm.mark(label, BrandMarks.image(.github, size: SettingsForm.markSize), "GitHub")
        #expect(label.accessibilityLabel() == "GitHub")
        SettingsForm.mark(nil, BrandMarks.image(.github, size: SettingsForm.markSize), "GitHub")
        SettingsForm.mark(label, tool: .codex)
        #expect(label.accessibilityLabel() == "Codex")
    }

    @Test func actionControlsReportTheirChoice() {
        UITestSupport.bootstrap()
        var pressed = 0
        let button = ActionButton(title: "Go") { pressed += 1 }
        button.performClick(nil)
        #expect(pressed == 1)

        var chosen: [String?] = []
        let popup = SettingsForm.popup(accessibility: "Choice") { chosen.append($0.selectedValue) }
        popup.addItem("A", value: "a")
        popup.addItem("B", value: "b")
        #expect(!popup.select(value: "z"))
        popup.settingsChoose(value: "b")
        #expect(chosen == ["b"])

        var segments: [Int] = []
        let control = SettingsForm.segmented(["One", "Two"], accessibility: "Seg") { segments.append($0) }
        control.settingsChoose(1)
        #expect(segments == [1])
        #expect(control.segmentCount == 2)
    }

    @Test func themeSwatchesDrawInBothAppearances() {
        UITestSupport.bootstrap()
        for choice in Theme.Choice.allCases {
            for dark in [false, true] {
                let image = ThemeSwatch.image(choice, dark: dark)
                #expect(image.size == ThemeSwatch.size)
                #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
            }
        }
        #expect(ThemeSwatch.image(.nord).size == ThemeSwatch.size)
    }

    @Test func paneContentPresentsErrorsOnlyWithAWindow() {
        UITestSupport.bootstrap()
        let suite = "GitaUITests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let content = SettingsPaneContent(environment: SettingsEnvironment(defaults: defaults))
        content.present(SettingsTestError()) // no window: nothing shown
        content.refresh()
        content.didAppear()
        content.didDisappear()
        content.applicationDidBecomeActive()
        let toggle = content.toggle(.showsAvatars, accessibility: "Avatars")
        toggle.settingsPress()
        #expect(Preference.showsAvatars.bool(defaults))
        toggle.settingsPress()
        #expect(!Preference.showsAvatars.bool(defaults))
        #expect(toggle.accessibilityIdentifier().isEmpty)
    }
}
