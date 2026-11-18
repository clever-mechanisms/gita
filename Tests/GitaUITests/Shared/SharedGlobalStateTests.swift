import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// Tests that change process-wide state (theme, interface font, author colour store); each restores it.
@MainActor
@Suite(.serialized)
struct SharedGlobalStateTests {
    @Test func applyingAThemeSwitchesTokensRefreshesWindowsAndPostsOnce() throws {
        UITestSupport.bootstrap()
        let previous = Theme.current
        let next: Theme.Choice = previous == .nord ? .dracula : .nord
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        host.addSubview(table)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let posts = SharedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .gitaThemeChanged, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { posts.value += 1 } }
        defer {
            NotificationCenter.default.removeObserver(observer)
            Theme.apply(previous)
            window.close()
        }
        Theme.apply(next)
        Theme.apply(next)
        #expect(Theme.current == next)
        #expect(posts.value == 1)
        let aqua = try #require(NSAppearance(named: .aqua))
        var drawn: NSColor?
        aqua.performAsCurrentDrawingAppearance { drawn = Theme.window.usingColorSpace(.sRGB) }
        let expected = Theme.resolve(.window, dark: false, choice: next).usingColorSpace(.sRGB)
        #expect(drawn == expected)
        #expect(table.needsDisplay)
    }

    @Test func authorColoursAreAssignedLeastUsedFirstAndRemembered() {
        let (defaults, name) = SharedFixtures.scratchDefaults()
        let previous = Theme.authorStore
        Theme.authorStore = defaults
        defer {
            Theme.authorStore = previous
            SharedFixtures.remove(name)
        }
        let ada = Theme.authorColorIndex("Ada Lovelace")
        let grace = Theme.authorColorIndex("Grace Hopper")
        #expect(ada != grace)
        #expect(Theme.authorColorIndex("  ada lovelace") == ada)
        let stored = defaults.dictionary(forKey: Preference.authorColors.rawValue) as? [String: Int]
        #expect(stored?["grace hopper"] == grace)
        // A fresh read from the store keeps the assignments and drops out-of-range ones.
        defaults.set(["ada lovelace": ada, "broken": 99], forKey: Preference.authorColors.rawValue)
        Theme.authorStore = defaults
        #expect(Theme.authorColorIndex("Ada Lovelace") == ada)
        #expect(Theme.authorColorIndex("Broken") == Theme.leastUsedColor(among: ["ada lovelace": ada], count: 9))
    }

    @Test func authorAssignmentsStartOverPastTheLimit() {
        let (defaults, name) = SharedFixtures.scratchDefaults()
        let previous = Theme.authorStore
        Theme.authorStore = defaults
        defer {
            Theme.authorStore = previous
            SharedFixtures.remove(name)
        }
        for index in 0..<2_000 { _ = Theme.authorColorIndex("author \(index)") }
        #expect(Theme.authorColorIndex("one more") == 0)
        let stored = defaults.dictionary(forKey: Preference.authorColors.rawValue) as? [String: Int]
        #expect(stored?.count == 1)
    }

    @Test func leastUsedColourPrefersTheLowestIndexOnATie() {
        #expect(Theme.leastUsedColor(among: [:], count: 3) == 0)
        #expect(Theme.leastUsedColor(among: ["a": 0, "b": 1], count: 3) == 2)
        #expect(Theme.leastUsedColor(among: ["a": 0, "b": 0, "c": 1, "d": 7], count: 2) == 1)
        #expect(Theme.leastUsedColor(among: [:], count: 0) == 0)
    }

    @Test func interfaceFontSwitchRefontsOpenWindowsAndSwitchesBack() throws {
        UITestSupport.bootstrap()
        let (defaults, name) = SharedFixtures.scratchDefaults()
        let previousStore = InterfaceFont.store
        InterfaceFont.store = defaults
        defer {
            InterfaceFont.apply(.system)
            InterfaceFont.store = previousStore
            TextLines.interfaceFontChanged()
            SharedFixtures.remove(name)
        }
        #expect(InterfaceFont.current == .system)
        let views = SharedInterfaceFontViews()
        let window = SharedEvents.window(containing: views.root)
        defer { window.close() }
        let posts = SharedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .gitaInterfaceFontChanged, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { posts.value += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        let menlo = InterfaceFont(face: .menlo)
        InterfaceFont.apply(menlo)
        InterfaceFont.apply(menlo)
        #expect(posts.value == 1)
        #expect(InterfaceFont.current == menlo)
        #expect(defaults.string(forKey: Preference.interfaceFont.rawValue) == "mono:menlo")
        let family = menlo.make(12).familyName
        #expect(views.field.font?.familyName == family)
        let labelFont = views.label.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(labelFont?.familyName == family)
        #expect(views.textView.font?.familyName == family)
        #expect(views.popup.font?.familyName != family)
        #expect(views.code.font === TextLines.monospaced(11))
        if case .text(_, let font, _) = try #require(views.button.parts.first) {
            #expect(font.familyName == family)
        }
        #expect(views.placeholderFamily == family)

        InterfaceFont.apply(.system)
        #expect(views.field.font?.familyName == NSFont.systemFont(ofSize: 12).familyName)
    }

    @Test func replacementKeepsSizeWeightAndDigitFeatures() {
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let next = InterfaceFont.replacement(for: digits)
        #expect(next?.pointSize == 13)
        #expect(InterfaceFont.replacement(for: TextLines.monospaced(11)) == nil)
        #expect(InterfaceFont.replacement(for: NSFont(name: "Menlo", size: 11) ?? .systemFont(ofSize: 1)) == nil)
    }
}

/// A small hierarchy with every kind of text a live font switch handles.
@MainActor
struct SharedInterfaceFontViews {
    let root = NSView()
    let field = NSTextField(string: "editable")
    let label = NSTextField(
        labelWithAttributedString: NSAttributedString(
            string: "label", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let code = NSTextField(labelWithString: "code")
    let search = NSSearchField(string: "")
    let button = PartsButton(
        [.text("Parts", font: NSFont.systemFont(ofSize: 12), color: .labelColor), .gap(4)], accessibility: "Parts")
    let titled = NSButton(title: "Title", target: nil, action: nil)

    init() {
        field.font = NSFont.systemFont(ofSize: 12)
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.string = "text"
        popup.font = NSFont.systemFont(ofSize: 12)
        code.font = TextLines.monospaced(11)
        search.placeholderAttributedString = NSAttributedString(
            string: "Search", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        titled.attributedTitle = NSAttributedString(
            string: "Title", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        for view in [field, label, textView, popup, code, search, button, titled] as [NSView] { root.addSubview(view) }
    }

    var placeholderFamily: String? {
        (search.placeholderAttributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName
    }
}
