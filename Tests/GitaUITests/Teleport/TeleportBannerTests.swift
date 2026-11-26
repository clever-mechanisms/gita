import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
struct TeleportBannerTests {
    @Test(arguments: [1, 2, 3]) func selectThenConfirmThroughFacade(shortcut: Int) async throws {
        UITestSupport.bootstrap()
        let facade = TeleportFacade()
        let banner = facade.makeTeleportBannerView()
        let presenter = facade.teleportPresenter
        let repos = ["One", "Two", "Three", "Four"].map {
            TeleportRepositoryEntry(
                workspaceID: $0, workspaceTitle: $0, repoPath: URL(filePath: "/tmp/" + $0),
                displayName: "App", githubSlug: "o/r")
        }
        var chosen: TeleportDestination?
        facade.onTeleport = { chosen = $0 }
        #expect(banner.isHidden)
        let url = try #require(URL(string: "gita://open?repo=o/r&pr=42"))
        #expect(facade.handleDeepLink(url, repositories: repos))
        guard case .resolving = presenter.state else {
            Issue.record("Expected immediate feedback")
            return
        }
        try await TeleportTestSupport.until { if case .ambiguous = presenter.state { true } else { false } }
        TeleportTestSupport.render(banner, width: 480, height: 160)
        #expect(TeleportTestSupport.child("teleport.banner.more", in: banner) != nil)
        presenter.selectAmbiguous(at: 30)
        guard case .ambiguous(_, let options) = presenter.state else { return }
        let choice = try #require(TeleportTestSupport.child("teleport.banner.choice.\(shortcut - 1)", in: banner))
        #expect(choice.toolTip?.contains("⌘\(shortcut)") == true)
        let event = try TeleportTestSupport.key(0, text: String(shortcut), flags: [.command, .capsLock])
        #expect(!banner.performKeyEquivalent(with: event))
        let host = NSViewController()
        host.view = banner
        let window = UITestSupport.host(host)
        defer { window.close() }
        #expect(window.makeFirstResponder(choice))
        #expect(banner.performKeyEquivalent(with: event))
        guard case .resolved(let destination) = presenter.state else {
            Issue.record("Expected selected destination")
            return
        }
        TeleportTestSupport.render(banner, width: 480, height: 44)
        #expect(destination == options[shortcut - 1])
        let enter = try TeleportTestSupport.key(KeyPress.keypadEnter, text: "\r", flags: .capsLock)
        #expect(window.makeFirstResponder(window))
        #expect(!banner.performKeyEquivalent(with: enter))
        let confirm = try #require(TeleportTestSupport.child("teleport.banner.confirm", in: banner))
        #expect(window.makeFirstResponder(confirm))
        #expect(banner.performKeyEquivalent(with: enter))
        #expect(chosen == destination && presenter.state == .idle && banner.isHidden)
        facade.inspectPaletteInput("missing", repositories: [])
        try await TeleportTestSupport.until { if case .notFound = presenter.state { true } else { false } }
        facade.inspectPaletteInput("push changes", repositories: repos)
        #expect(banner.isHidden)
    }

    @Test func dismissCancelsResolution() async throws {
        UITestSupport.bootstrap()
        let runner = TeleportUIRunner { _ in
            try await Task.sleep(for: .seconds(30))
            return TeleportUIRunner.result()
        }
        let presenter = TeleportPresenter(resolver: .init(runner: runner))
        let banner = TeleportBannerView(presenter: presenter)
        presenter.inspect(
            "main",
            repositories: [
                .init(workspaceID: "w", workspaceTitle: "Work", repoPath: URL(filePath: "/tmp"), displayName: "App")
            ])
        let spinner = try #require(TeleportTestSupport.child("teleport.banner.spinner", in: banner))
        let icon = try #require(spinner.superview?.subviews.first { $0 is NSImageView })
        #expect(spinner.isHidden && !icon.isHidden)
        try await TeleportTestSupport.until { !spinner.isHidden }
        #expect(icon.isHidden && spinner.isDescendant(of: banner))
        presenter.dismiss()
        await Task.yield()
        #expect(presenter.state == .idle && banner.isHidden)
    }
}
