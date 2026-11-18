import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite struct SharedPartsButtonTests {
    private static let image = NSImage(size: NSSize(width: 8, height: 8))

    private func allParts() -> [PartsButton.Part] {
        [
            .symbol("star.fill", color: Theme.text, size: 12), .gap(10),
            .text("Title", font: Theme.body, color: Theme.text),
            .mark(AgentMarkState(tool: .claudeCode, state: .working)),
            .badge("12", fill: Theme.accent, color: Deck.onAccent), .image(Self.image, size: 16),
            .symbol("not-a-real-symbol-name", color: Theme.text, size: 12),
        ]
    }

    private func render(_ button: PartsButton, width: CGFloat = 220) {
        button.frame = NSRect(x: 0, y: 0, width: width, height: button.fixedHeight)
        button.layoutSubtreeIfNeeded()
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = NSAppearance(named: name)
            UITestSupport.render(button)
        }
    }

    @Test func measuresEveryKindOfPart() {
        let button = PartsButton(allParts(), accessibility: "All")
        #expect(button.contentWidth > 0)
        #expect(button.intrinsicContentSize.height == 24)
        #expect(button.intrinsicContentSize.width == ceil(button.contentWidth + 16))
        #expect(PartsButton([], accessibility: "Empty").contentWidth == 0)
        #expect(button.subviews.count == 1, "one mark view per mark part")
        button.parts = [.text("Only", font: Theme.body, color: Theme.text)]
        #expect(button.subviews.isEmpty)
        #expect(button.isFlipped)
        #expect(button.acceptsFirstMouse(for: nil))
        #expect(button.accessibilityLabel() == "All")
    }

    @Test(arguments: [
        PartsButton.Background.none, .hover, .quiet, .accent, .tinted, .selected,
    ])
    func drawsEveryBackgroundEnabledAndDisabled(background: PartsButton.Background) throws {
        for alignment in [NSTextAlignment.left, .right, .center] {
            let button = PartsButton(allParts(), background: background, accessibility: "Draw")
            button.contentAlignment = alignment
            render(button)
            button.isEnabled = false
            render(button, width: 40)
            #expect(!button.acceptsFirstResponder)
        }
        let button = PartsButton(allParts(), background: background, accessibility: "Draw")
        let window = SharedEvents.window(containing: button, size: NSSize(width: 220, height: 24))
        defer { window.close() }
        button.mouseEntered(with: try #require(SharedEvents.mouse(.mouseMoved, at: .zero, in: button)))
        #expect(button.isHovering)
        render(button)
        button.mouseExited(with: try #require(SharedEvents.mouse(.mouseMoved, at: .zero, in: button)))
        #expect(!button.isHovering)
        button.updateTrackingAreas()
        #expect(button.trackingAreas.count == 1)
        button.viewDidChangeEffectiveAppearance()
        #expect(button.focusRingMaskBounds == button.bounds)
    }

    @Test func clickWithoutAWindowFiresOnClick() throws {
        var clicks = 0
        let button = PartsButton([.text("Go", font: Theme.body, color: Theme.text)], accessibility: "Go") {
            clicks += 1
        }
        button.mouseDown(with: try #require(SharedEvents.mouse(.leftMouseDown, at: .zero, in: button)))
        #expect(clicks == 1)
        button.isEnabled = false
        button.mouseDown(with: try #require(SharedEvents.mouse(.leftMouseDown, at: .zero, in: button)))
        #expect(clicks == 1)
        #expect(!button.accessibilityPerformPress())
        #expect(button.accessibilityRole() == .button)
        #expect(button.isAccessibilityElement())
    }

    @Test func keysAndAccessibilityPressPerform() throws {
        var clicks = 0
        let button = PartsButton([.gap(4)], accessibility: "Keys") { clicks += 1 }
        let recorder = SharedResponderRecorder()
        button.nextResponder = recorder
        button.keyDown(with: try #require(SharedEvents.key(" ", code: KeyPress.space)))
        button.keyDown(with: try #require(SharedEvents.key("\r", code: KeyPress.returnKey)))
        button.keyDown(with: try #require(SharedEvents.key("a", code: 0)))
        #expect(clicks == 2)
        #expect(recorder.keys == [0])
        #expect(button.accessibilityPerformPress())
        #expect(clicks == 3)
        #expect(button.acceptsFirstResponder)
    }

    @Test func withoutOnClickAPressSendsTheControlAction() {
        UITestSupport.bootstrap()
        let button = PartsButton([.gap(4)], accessibility: "Action")
        #expect(button.accessibilityPerformPress(), "an enabled button takes the press even with no handler")
    }

    @Test func aMenuProviderWithoutAMenuFallsBackToTheClick() throws {
        var asked = 0
        var clicks = 0
        let button = PartsButton([.gap(4)], accessibility: "Menu") { clicks += 1 }
        button.menuProvider = {
            asked += 1
            return nil
        }
        #expect(button.accessibilityRole() == .popUpButton)
        button.mouseDown(with: try #require(SharedEvents.mouse(.leftMouseDown, at: .zero, in: button)))
        #expect(asked == 1)
        #expect(clicks == 1)
    }

    @Test func commonShapesCarryTheirMetrics() {
        var opened = 0
        let open = PartsButton.openButton(small: true) {
            opened += 1
            return URL(string: "https://github.com/octo/repo")
        }
        #expect(open.fixedHeight == 20)
        #expect(open.background == .accent)
        #expect(open.parts.count == 3, "GitHub mark, title, arrow")
        let large = PartsButton.openButton("Visit") { URL(string: "http://example.invalid") }
        #expect(large.fixedHeight == 26)
        #expect(large.parts.count == 2)
        #expect(large.accessibilityPerformPress(), "a non-https address is refused, nothing opens")

        var quietClicks = 0
        let quiet = PartsButton.quiet("Fetch", symbol: "arrow.down") { quietClicks += 1 }
        #expect(quiet.parts.count == 2)
        #expect(quiet.horizontalPadding == 9)
        let iconOnly = PartsButton.quiet("", symbol: "doc.on.doc") {}
        #expect(iconOnly.accessibilityLabel() == "doc.on.doc")
        #expect(iconOnly.horizontalPadding == 6)
        _ = quiet.accessibilityPerformPress()
        #expect(quietClicks == 1)

        let link = PartsButton.link("More", size: 12) {}
        #expect(link.background == .none)
        #expect(link.fixedHeight == 16)

        let app = PartsButton.app("Open in Orca", icon: Self.image, filled: true) {}
        #expect(app.background == .accent)
        #expect(app.horizontalPadding == 7)
        let plainApp = PartsButton.app("Open", icon: nil) {}
        #expect(plainApp.background == .quiet)
        #expect(plainApp.horizontalPadding == 10)
        #expect(opened >= 1)
    }
}
