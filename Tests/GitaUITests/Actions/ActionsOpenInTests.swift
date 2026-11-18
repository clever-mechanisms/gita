import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// "Open in": the terminal and editor chosen in Settings or the first installed fallback, handed the folder through
/// a recording opener, and the GitHub page of a remote.
@MainActor
struct ActionsOpenInTests {
    private static let folder = URL(fileURLWithPath: "/tmp/checkout", isDirectory: true)

    @Test func theChosenTerminalWinsOverTerminalWhenInstalled() throws {
        let sandbox = try AgentsSandbox("Actions")
        let terminal = URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")
        let ghostty = URL(fileURLWithPath: "/Applications/Ghostty.app")
        let recorder = ActionsRecordingOpener(apps: [OpenIn.defaultTerminal: terminal])
        OpenIn.terminal(Self.folder, opener: recorder.opener, defaults: sandbox.defaults)
        Preference.terminalBundleID.set("com.mitchellh.ghostty", sandbox.defaults)
        OpenIn.terminal(Self.folder, opener: recorder.opener, defaults: sandbox.defaults)
        recorder.apps["com.mitchellh.ghostty"] = ghostty
        OpenIn.terminal(Self.folder, opener: recorder.opener, defaults: sandbox.defaults)
        #expect(
            recorder.calls == [
                .open(documents: [Self.folder], app: terminal), .open(documents: [Self.folder], app: terminal),
                .open(documents: [Self.folder], app: ghostty),
            ])
    }

    @Test func theEditorFallsBackThroughTheCandidatesAndNothingOpensWithoutOne() throws {
        let sandbox = try AgentsSandbox("Actions")
        let zed = URL(fileURLWithPath: "/Applications/Zed.app")
        let recorder = ActionsRecordingOpener()
        OpenIn.editor(Self.folder, opener: recorder.opener, defaults: sandbox.defaults)
        OpenIn.terminal(Self.folder, opener: recorder.opener, defaults: sandbox.defaults)
        #expect(recorder.calls.isEmpty)
        recorder.apps["dev.zed.Zed"] = zed
        OpenIn.editor(Self.folder, opener: recorder.opener, defaults: sandbox.defaults)
        OpenIn.finder(Self.folder, opener: recorder.opener)
        #expect(recorder.calls == [.open(documents: [Self.folder], app: zed), .reveal([Self.folder])])
        #expect(OpenIn.editorApp(recorder.opener, defaults: sandbox.defaults) == zed)
        #expect(OpenIn.terminalApp(recorder.opener, defaults: sandbox.defaults) == nil)
    }

    @Test func theBuiltInTerminalOpensInGitaAndNamesItself() throws {
        let sandbox = try AgentsSandbox("Actions")
        let terminal = URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")
        let recorder = ActionsRecordingOpener(apps: [OpenIn.defaultTerminal: terminal])
        #expect(OpenIn.terminalChoice(recorder.opener, defaults: sandbox.defaults)?.name == "Terminal")
        #expect(!OpenIn.usesBuiltInTerminal(sandbox.defaults))
        Preference.terminalBundleID.set(OpenIn.builtInTerminal, sandbox.defaults)
        #expect(OpenIn.usesBuiltInTerminal(sandbox.defaults))
        let choice = try #require(OpenIn.terminalChoice(recorder.opener, defaults: sandbox.defaults))
        #expect(choice.name == OpenIn.builtInTerminalName)
        #expect(choice.icon != nil)
        OpenIn.terminal(Self.folder, opener: recorder.opener, defaults: sandbox.defaults)
        #expect(recorder.calls == [.builtInTerminal(directory: Self.folder, script: nil)])
        #expect(OpenIn.terminalChoice(ActionsRecordingOpener().opener, defaults: sandbox.defaults) != nil)
        Preference.terminalBundleID.set("", sandbox.defaults)
        #expect(OpenIn.terminalChoice(ActionsRecordingOpener().opener, defaults: sandbox.defaults) == nil)
    }

    @Test func appNamesDropTheExtension() {
        #expect(OpenIn.name(URL(fileURLWithPath: "/Applications/Visual Studio Code.app")) == "Visual Studio Code")
    }

    @Test func siteLinksUseConfiguredHostAndRepository() {
        #expect(ProductWebsite.host(from: "") == nil)
        #expect(Website.host == Website.defaultHost)
        #expect(Website.home?.host() == Website.defaultHost)
        #expect(Website.repository?.absoluteString == "https://github.com/clever-mechanisms/gita")
        #expect(BugReport.issues == "https://github.com/clever-mechanisms/gita/issues/new")
        #expect(Website.url("x", campaign: "c", content: "d")?.path() == "/x")
    }
}
