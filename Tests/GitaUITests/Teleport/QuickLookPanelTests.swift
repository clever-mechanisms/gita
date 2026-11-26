import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
struct QuickLookPanelTests {
    private let root = URL(filePath: "/tmp")
    private func target(_ path: String) -> QuickLookTarget {
        .changedFile(repoPath: root, path: path, staged: true, statusCode: .modified)
    }

    @Test func panelIsLazyAndHandlesNavigation() throws {
        UITestSupport.bootstrap()
        let facade = TeleportFacade(runner: TeleportUIRunner { _ in TeleportUIRunner.result(code: 1) })
        let controller = facade.quickLookController
        let file = target("src/file")
        let second = target("second")
        facade.updateQuickLookSelection(file)
        #expect(controller.panel == nil && !facade.isQuickLookVisible)
        var navigation: [QuickLookNavigationDirection] = []
        var opened: QuickLookTarget?
        facade.onQuickLookNavigate = { navigation.append($0) }
        facade.onQuickLookOpenFull = { opened = $0 }
        facade.toggleQuickLook(for: file)
        let panel = try #require(controller.panel)
        #expect(panel.isVisible && panel.isFloatingPanel && panel.styleMask.contains(.nonactivatingPanel))
        panel.sendEvent(try TeleportTestSupport.key(126, text: "\u{F700}", flags: [.function, .numericPad]))
        panel.sendEvent(try TeleportTestSupport.key(125, text: "\u{F701}", flags: [.function, .numericPad]))
        #expect(navigation == [.previous, .next])
        facade.updateQuickLookSelection(second)
        panel.sendEvent(try TeleportTestSupport.key(36, text: "\r"))
        #expect(opened == second && !facade.isQuickLookVisible)
        for (code, text): (UInt16, String) in [(49, " "), (53, "\u{1b}")] {
            controller.show(for: file)
            panel.sendEvent(try TeleportTestSupport.key(code, text: text))
            #expect(!controller.isVisible)
        }
        facade.closeQuickLook()
    }

    @Test func retryReceivesSpaceAndReturnWhileFocused() throws {
        UITestSupport.bootstrap()
        let controller = GitaQuickLookPanelController()
        let file = target("file")
        controller.show(for: file)
        defer { controller.close() }
        let panel = try #require(controller.panel)
        let view = try #require(panel.contentView as? QuickLookPreviewView)
        view.display(.failed(file, "Unavailable"))
        var retries = 0
        view.onRetry = { retries += 1 }
        let retry = try #require(TeleportTestSupport.child("teleport.quickLook.retry", in: view))
        #expect(panel.makeFirstResponder(retry))
        panel.sendEvent(try TeleportTestSupport.key(KeyPress.space, text: " "))
        panel.sendEvent(try TeleportTestSupport.key(KeyPress.returnKey, text: "\r"))
        #expect(retries == 2 && controller.isVisible)
    }

    private final class AnchorWindow: NSWindow {
        private(set) var keyRequests = 0
        override func makeKey() {
            keyRequests += 1
            super.makeKey()
        }
    }

    @Test func restoresVisibleAnchorOnClose() throws {
        UITestSupport.bootstrap()
        let anchor = AnchorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: true)
        anchor.isReleasedWhenClosed = false
        defer { anchor.close() }
        anchor.orderFrontRegardless()
        let controller = GitaQuickLookPanelController()
        controller.show(for: target("file"), relativeTo: anchor)
        let panel = try #require(controller.panel)
        #expect(panel.firstResponder === panel.contentView)
        #expect(panel.hidesOnDeactivate && panel.collectionBehavior == [.fullScreenAuxiliary])
        let before = anchor.keyRequests
        controller.close()
        #expect(anchor.keyRequests > before)

        anchor.orderOut(nil)
        controller.show(for: target("another"), relativeTo: anchor)
        let hidden = anchor.keyRequests
        controller.close()
        #expect(anchor.keyRequests == hidden)
    }

    @Test func binaryFileOffersOpenInMainWindow() async throws {
        UITestSupport.bootstrap()
        let runner = TeleportUIRunner { args in
            if args.contains("--show-toplevel") { return TeleportUIRunner.result("/tmp\n") }
            if args.contains("config") { return TeleportUIRunner.result(code: 1) }
            return TeleportUIRunner.result("Binary files a/image and b/image differ\n")
        }
        let content = try await QuickLookPreviewLoader(runner: runner).load(target("image"))
        let view = QuickLookPreviewView()
        var opened = false
        view.onOpenFull = { opened = true }
        view.display(.loaded(content))
        let button = try #require(TeleportTestSupport.child("teleport.quickLook.openFull", in: view) as? PartsButton)
        let labels = button.superview?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels?.contains("Binary file, no text preview") == true)
        #expect(TeleportTestSupport.child("teleport.quickLook.diff", in: view) == nil)
        #expect(button.accessibilityLabel() == "Open in Main Window")
        #expect(button.accessibilityPerformPress() && opened)
    }

    @Test func previewsRealCommitAndStash() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let sha = try repo.commit("file.txt", "before\n", message: "First revision")
        let loader = QuickLookPreviewLoader()
        let content = try await loader.load(.commit(repoPath: repo.url, sha: String(sha.prefix(9))))
        #expect(content.commitSHA == sha && content.title == "First revision")
        #expect(content.files.map(\.path) == ["file.txt"])
        try repo.write("file.txt", "after\n")
        try repo.write("new file.txt", "saved\n")
        try repo.git("stash", "push", "--include-untracked", "-m", "Saved edits")
        let stash = try await loader.load(.stash(repoPath: repo.url, ref: "stash@{0}", message: nil))
        #expect(stash.title.contains("Saved edits"))
        #expect(Set(stash.files.map(\.path)) == ["file.txt", "new file.txt"])
        #expect(stash.diffExcerpt.lines.contains("+saved") && stash.diffExcerpt.lines.contains("+after"))
        let view = QuickLookPreviewView()
        view.display(.loaded(stash))
        TeleportTestSupport.render(view, width: 480, height: 340)
        let files = try #require(TeleportTestSupport.child("teleport.quickLook.files", in: view))
        #expect(files.bounds.height > 0)
    }

    @Test func selectionCancelsSlowDiffAndResetsSpinner() async throws {
        UITestSupport.bootstrap()
        let slow = target("slow")
        let fast = target("fast")
        let (cancelled, signal) = AsyncStream<Void>.makeStream()
        let runner = TeleportUIRunner { args in
            if args.contains("--show-toplevel") { return TeleportUIRunner.result("/tmp\n") }
            if args.contains("config") { return TeleportUIRunner.result(code: 1) }
            if args.last == "slow" {
                do { try await Task.sleep(for: .seconds(30)) } catch {
                    signal.yield()
                    throw error
                }
            }
            return TeleportUIRunner.result(
                "diff --git a/fast b/fast\n--- a/fast\n+++ b/fast\n@@ -1 +1 @@\n-before\n+after\n")
        }
        let presenter = QuickLookPresenter(loader: .init(runner: runner))
        let view = QuickLookPreviewView()
        presenter.attach(view)
        presenter.select(slow)
        #expect(presenter.state == .loading(slow, showsSpinner: false))
        let spinner = try #require(TeleportTestSupport.child("teleport.quickLook.spinner", in: view))
        #expect(spinner.isHidden)
        try await TeleportTestSupport.until { presenter.state == .loading(slow, showsSpinner: true) }
        #expect(!spinner.isHidden && spinner.isDescendant(of: view))
        presenter.select(fast)
        #expect(presenter.state == .loading(fast, showsSpinner: false))
        try await TeleportTestSupport.until { if case .loaded = presenter.state { true } else { false } }
        signal.finish()
        var cancellation = cancelled.makeAsyncIterator()
        #expect(await cancellation.next() != nil)
        guard case .loaded(let content) = presenter.state else {
            Issue.record("Expected fast preview")
            return
        }
        #expect(content.target == fast)
        TeleportTestSupport.render(view, width: 600, height: 400)
        let diff = try #require(TeleportTestSupport.child("teleport.quickLook.diff", in: view) as? NSTextView)
        #expect(diff.string.contains("+after") && !diff.isEditable)
        let selected = NSRange(location: 3, length: 5)
        diff.setSelectedRange(selected)
        let oldScroll = try #require(diff.enclosingScrollView)
        let scrollOrigin = oldScroll.contentView.bounds.origin
        TeleportTestSupport.render(view, width: 600, height: 400)
        #expect(diff.isDescendant(of: view) && diff.selectedRange() == selected)
        #expect(oldScroll.contentView.bounds.origin == scrollOrigin)
        var diffNav: [QuickLookNavigationDirection] = []
        var diffOpened = false
        var diffClosed = false
        view.onNavigate = { diffNav.append($0) }
        view.onOpenFull = { diffOpened = true }
        view.onClose = { diffClosed = true }
        let host = NSViewController()
        host.view = view
        let hostWindow = UITestSupport.host(host, size: NSSize(width: 600, height: 400))
        defer { hostWindow.close() }
        #expect(hostWindow.makeFirstResponder(diff))
        diff.keyDown(with: try TeleportTestSupport.key(KeyPress.upArrow, text: "\u{F700}", flags: [.function]))
        diff.keyDown(with: try TeleportTestSupport.key(KeyPress.downArrow, text: "\u{F701}", flags: [.function]))
        diff.keyDown(with: try TeleportTestSupport.key(KeyPress.returnKey, text: "\r"))
        diff.keyDown(with: try TeleportTestSupport.key(KeyPress.space, text: " "))
        #expect(diffNav == [.previous, .next] && diffOpened && diffClosed)
        presenter.select(slow)
        #expect(presenter.currentTarget == slow && presenter.state == .loaded(content))
        #expect(diff.isDescendant(of: view))
        try await TeleportTestSupport.until { presenter.state == .loading(slow, showsSpinner: true) }
        presenter.clear()
        #expect(presenter.currentTarget == nil && presenter.state == .idle)
    }
}
