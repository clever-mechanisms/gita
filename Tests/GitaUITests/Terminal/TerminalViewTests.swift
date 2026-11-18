import AppKit
import Foundation
import Testing
import WebKit

@testable import GitaCore
@testable import GitaUI

/// The terminal's web view, with a session whose program never starts (no page is loaded in tests, so
/// the page is never ready).
@MainActor
@Suite("Built-in terminal view")
struct TerminalViewTests {
    private static let folder = URL(fileURLWithPath: "/tmp/checkout", isDirectory: true)

    private func session() -> TerminalSession {
        TerminalSession(directory: Self.folder) { _, _, _, _ in throw POSIXError(.EPERM) }
    }

    @Test func pageMessagesReachTheSessionAndOnlyTheBundledPageLoads() throws {
        let session = session()
        let view = TerminalView(session: session, page: nil)
        var titles: [String] = []
        session.onTitle = { titles.append($0) }
        view.received(["type": "title", "title": "zsh"])
        view.received("not a message")
        #expect(titles == ["zsh"])
        #expect(view.webView.superview === view)
        #expect(view.webView.isHidden, "no white web view before the page has drawn")
        var early: [String] = []
        session.evaluate = { early.append($0) }
        view.focus()
        #expect(early.isEmpty, "focus waits for the page")
        view.webView(view.webView, didFinish: nil)
        #expect(!view.webView.isHidden)
        #expect(early == ["gita.focus()"], "and is given once it is up")
        #expect(view.webView.accessibilityLabel() == String(localized: "Terminal"))
        var scripts: [String] = []
        session.evaluate = { scripts.append($0) }
        view.viewDidChangeEffectiveAppearance()
        #expect(scripts.isEmpty, "nothing changed: nothing is sent")
        view.focus()
        #expect(scripts.last == "gita.focus()")
    }

    @Test func aSettingsChangeRecoloursTheTerminal() throws {
        let sandbox = try AgentsSandbox("Terminal")
        let session = session()
        let view = TerminalView(session: session, page: nil, defaults: sandbox.defaults)
        var scripts: [String] = []
        session.evaluate = { scripts.append($0) }
        let dark = view.look.background
        Preference.terminalColors.set(TerminalColors.light.rawValue, sandbox.defaults)
        #expect(view.look.background != dark)
        #expect(scripts.count == 1 && scripts.first?.hasPrefix("gita.configure({") == true)
        #expect(view.layer?.backgroundColor != nil)
        Preference.historyZoomPercent.set(110, sandbox.defaults)
        #expect(scripts.count == 1, "another setting: the look is the same, nothing is sent")
    }

    /// A page that reports ready gets the look the settings call for then, so a change made while it loaded (when
    /// `gita.configure` did not exist yet) is not lost.
    @Test func aReadyPageGetsTheCurrentLook() throws {
        let sandbox = try AgentsSandbox("Terminal")
        let session = session()
        let view = TerminalView(session: session, page: nil, defaults: sandbox.defaults)
        var scripts: [String] = []
        session.evaluate = { scripts.append($0) }
        Preference.terminalColors.set(TerminalColors.light.rawValue, sandbox.defaults)
        scripts.removeAll()
        view.received(["type": "ready", "cols": 80, "rows": 24])
        #expect(scripts.first == "gita.configure(\(view.look.json))")
    }

    @Test func theBundledPageIsTheOneTheBuildCopies() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Resources/Terminal").standardizedFileURL
        for file in ["index.html", "terminal.js", "xterm/xterm.js", "xterm/xterm.css", "xterm/addon-fit.js"] {
            #expect(FileManager.default.fileExists(atPath: resources.appendingPathComponent(file).path), "\(file)")
        }
        for license in ["xterm/LICENSE", "xterm/LICENSE-addon-fit"] {
            let text = try String(contentsOf: resources.appendingPathComponent(license), encoding: .utf8)
            #expect(text.contains("Permission is hereby granted, free of charge"))
        }
        let page = try String(contentsOf: resources.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(page.contains("default-src 'none'"), "the page reaches nothing outside the bundle")
        // Loading it (as the app does) needs a bundle; tests only check that a page folder is accepted.
        let view = TerminalView(session: session(), page: resources)
        #expect(view.webView.url == nil || view.webView.url?.isFileURL == true)
    }
}
