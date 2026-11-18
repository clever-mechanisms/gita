import AppKit
import Testing

@testable import GitaUI

@MainActor
@Suite("Windows about")
struct WindowsAboutTests {
    @Test func preparesTheWindowOnce() throws {
        UITestSupport.bootstrap()
        let controller = AboutWindowController()
        let window = controller.prepareWindow()
        #expect(controller.prepareWindow() === window)
        #expect(window.title == String(localized: "About Gitā"))
        #expect(window.contentView is AboutView)
        #expect(window.contentLayoutRect.width == AboutView.width)
        #expect(window.frame.height > 100)
        #expect(!window.isVisible)
        #expect(window.delegate === controller)
    }

    @Test func showsVersionAndCopiesItToThePasteboard() throws {
        UITestSupport.bootstrap()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitaUITests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let view = AboutView(pasteboard: pasteboard)
        view.layoutSubtreeIfNeeded()
        let texts = SetupTestSupport.views(NSTextField.self, in: view).map(\.stringValue)
        #expect(texts.contains("Gitā"))
        #expect(texts.contains("\(AppInfo.version) (\(AppInfo.build))"))
        #expect(texts.contains("\(AppInfo.system) · \(AppInfo.architecture)"))
        let links = SetupTestSupport.views(AboutLink.self, in: view)
        #expect(
            links.compactMap { $0.accessibilityLabel() } == [
                "getgita.app", "clever-mechanisms/gita", String(localized: "Report Bug"),
            ])
        let images = links.compactMap { SetupTestSupport.views(NSImageView.self, in: $0).first?.image }
        #expect(images.count == 3)
        #expect(images[1].accessibilityDescription == "GitHub")
        let copy = try #require(
            SetupTestSupport.views(NSButton.self, in: view).first {
                $0.title == String(localized: "Copy Version Info")
            })
        copy.performClick(nil)
        #expect(pasteboard.string(forType: .string) == AppInfo.summary)
        #expect(copy.title == String(localized: "Copied"))
        copy.performClick(nil)
        #expect(view.isFlipped)
        view.frame.size = view.fittingSize
        UITestSupport.render(view)
    }

    @Test func appInfoDescribesThisCopy() {
        #expect(AppInfo.summary.hasPrefix("Gitā \(AppInfo.version) (\(AppInfo.build)"))
        #expect(AppInfo.summary.hasSuffix(AppInfo.architecture))
        #expect(AppInfo.system.hasPrefix("macOS "))
        #expect(AppInfo.revision == nil || AppInfo.revision?.count ?? 0 <= 7)
    }

    @Test func linkOpensOnPressAndOnClickInside() throws {
        UITestSupport.bootstrap()
        let url = try #require(URL(string: "https://example.invalid/notes"))
        let link = AboutLink(title: "Release Notes", symbol: "doc.text", url: url)
        var opened: [URL] = []
        link.openURL = { opened.append($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = link
        link.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        #expect(link.toolTip == "example.invalid")
        #expect(link.isAccessibilityElement())
        #expect(link.accessibilityRole() == .link)
        #expect(link.accessibilityLabel() == "Release Notes")
        #expect(link.accessibilityPerformPress())
        let inside = try Self.mouse(.leftMouseUp, at: NSPoint(x: 10, y: 10), in: window)
        link.mouseDown(with: try Self.mouse(.leftMouseDown, at: NSPoint(x: 10, y: 10), in: window))
        #expect(link.alphaValue < 1)
        link.mouseUp(with: inside)
        #expect(link.alphaValue == 1)
        link.mouseUp(with: try Self.mouse(.leftMouseUp, at: NSPoint(x: 500, y: 500), in: window))
        #expect(opened == [url, url])
        link.resetCursorRects()
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
