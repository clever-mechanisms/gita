import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Tabs: badges, neutral surface, accessibility & reduce motion")
struct TabsBadgeAndThemeTests {
    private static func luminance(of color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    private static func contrast(_ foreground: NSColor, on background: NSColor) -> CGFloat {
        var resolvedBG = background
        var resolvedFG = foreground
        if let appearance = NSAppearance.currentDrawing() as NSAppearance? {
            appearance.performAsCurrentDrawingAppearance {
                resolvedBG = background.usingColorSpace(.sRGB) ?? background
                resolvedFG = foreground.usingColorSpace(.sRGB) ?? foreground
            }
        }
        let l1 = luminance(of: resolvedFG)
        let l2 = luminance(of: resolvedBG)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test func needsInputCapsuleHasHighContrastInLightAndDark() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var ratio: CGFloat = 0
            appearance.performAsCurrentDrawingAppearance {
                ratio = Self.contrast(.white, on: Theme.needsInput)
            }
            #expect(ratio >= 4.5, "Expected >= 4.5:1 contrast in \(name.rawValue), got \(ratio)")
        }
    }

    @Test func tabGroupLineHeightIsTwoAndHalfPoints() {
        #expect(TabStripLayout.lineHeight == 2.5)
    }

    @Test func accessibilityLabelIncludesTabColorTitle() {
        let state = RepositoryTabState(
            name: "gita-app", branch: "main", agent: .needsInput, tool: .claudeCode, color: .red)
        #expect(state.accessibilityLabel == "gita-app, Red, main, Claude Code, Needs input")
        let noColor = RepositoryTabState(name: "gita-app", agent: .done, tool: .codex)
        #expect(noColor.accessibilityLabel == "gita-app, Codex, Done")
    }

    @Test func tabBadgeShortensNeedsInputBelow160AndFadesDoneWhenSeen() {
        UITestSupport.bootstrap()
        let view = RepositoryTabView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.update(RepositoryTabState(name: "api", agent: .needsInput, tool: .claudeCode, color: .orange))
        view.layoutSubtreeIfNeeded()
        #expect(!view.badgeView.isHidden)
        #expect(view.badgeView.badge == .needsInput)
        #expect(view.badgeView.text == "Needs input")

        // Narrower than 160 pt shortens the pill to ⚠︎.
        view.frame = NSRect(x: 0, y: 0, width: 140, height: 30)
        view.layoutSubtreeIfNeeded()
        #expect(view.badgeView.text == "⚠︎")

        // Done ✓ fades when marked seen or selected.
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
        view.update(RepositoryTabState(name: "api", agent: .done, tool: .claudeCode, selected: false, doneSeen: false))
        view.layoutSubtreeIfNeeded()
        #expect(view.badgeView.badge == .done)
        #expect(view.badgeView.text == "Done ✓")
        #expect(view.badgeView.alphaValue == 1)

        view.update(RepositoryTabState(name: "api", agent: .done, tool: .claudeCode, selected: false, doneSeen: true))
        #expect(view.badgeView.alphaValue == 0.55)

        // Working renders spinner only (no capsule badge).
        view.update(RepositoryTabState(name: "api", agent: .working, tool: .claudeCode))
        #expect(view.badgeView.badge == .none)
        #expect(view.badgeView.isHidden)
    }

    @Test func tabDrawsColorDotWithoutMarkAndRingWithMark() {
        UITestSupport.bootstrap()
        let view = RepositoryTabView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        // Dot only (no agent mark)
        view.update(RepositoryTabState(name: "docs", selected: true, color: .purple))
        view.layoutSubtreeIfNeeded()
        UITestSupport.render(view)
        // Ring around agent mark
        view.update(RepositoryTabState(name: "api", agent: .working, tool: .claudeCode, selected: false, color: .green))
        view.layoutSubtreeIfNeeded()
        UITestSupport.render(view)
        // Badge view renders both states
        view.badgeView.apply(.needsInput, compact: false, faded: false)
        view.badgeView.frame = NSRect(x: 0, y: 0, width: 80, height: 16)
        UITestSupport.render(view.badgeView)
        view.badgeView.apply(.done, compact: false, faded: true)
        UITestSupport.render(view.badgeView)
    }

    @Test func agentMarkViewStaysStaticWhenReduceMotionIsOn() {
        #expect(
            !AgentMarkView.shouldAnimate(
                hasTool: true, state: .working, visible: true, hidden: false, reduceMotion: true))
        #expect(
            AgentMarkView.shouldAnimate(
                hasTool: true, state: .working, visible: true, hidden: false, reduceMotion: false))
        #expect(
            !AgentMarkView.shouldAnimate(
                hasTool: true, state: .done, visible: true, hidden: false, reduceMotion: false))

        UITestSupport.bootstrap()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let mark = AgentMarkView(side: 14)
        var reduce = true
        mark.reduceMotion = { reduce }
        mark.isWindowVisible = { $0 != nil }
        mark.tool = .claudeCode
        mark.state = .working
        window.contentView?.addSubview(mark)
        window.orderFront(nil)
        defer { window.close() }
        mark.updateMotion()
        #expect(!mark.moving)

        reduce = false
        mark.updateMotion()
        #expect(mark.moving)

        reduce = true
        mark.updateMotion()
        #expect(!mark.moving)
    }
}
