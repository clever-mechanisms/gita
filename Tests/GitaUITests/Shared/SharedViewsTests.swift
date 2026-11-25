import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite struct SharedViewsTests {
    private func renderBoth(_ view: NSView) {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: name)
            UITestSupport.render(view)
        }
    }

    @Test func rowViewDrawsSelectionFillHoverAndSeparator() throws {
        let row = RowView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let window = SharedEvents.window(containing: row, size: NSSize(width: 120, height: 24))
        defer { window.close() }
        row.onClick = {}
        row.mouseEntered(with: try #require(SharedEvents.mouse(.mouseMoved, at: .zero, in: row)))
        #expect(row.isHovering)
        row.bottomSeparator = Theme.separator
        renderBoth(row)
        row.fill = Theme.inset
        renderBoth(row)
        row.isSelected = true
        row.isSelected = true
        renderBoth(row)
        row.mouseExited(with: try #require(SharedEvents.mouse(.mouseMoved, at: .zero, in: row)))
        #expect(!row.isHovering)
        row.updateTrackingAreas()
        #expect(row.trackingAreas.count == 1)
        row.viewDidChangeEffectiveAppearance()
        #expect(row.isFlipped)
        #expect(row.focusRingMaskBounds == row.bounds)
        #expect(row.acceptsClick(at: .zero))
    }

    @Test func rowViewClicksDoubleClicksAndPassesOtherMouseDowns() throws {
        let row = RowView(frame: .zero)
        let window = SharedEvents.window(containing: row, size: NSSize(width: 120, height: 24))
        defer { window.close() }
        let recorder = SharedResponderRecorder()
        row.nextResponder = recorder
        let inside = NSPoint(x: 10, y: 10)
        row.mouseDown(with: try #require(SharedEvents.mouse(.leftMouseDown, at: inside, in: row)))
        #expect(recorder.mouseDowns == 1, "no click handler: the click goes up the chain")
        var clicks = 0
        var doubles = 0
        row.onClick = { clicks += 1 }
        row.mouseDown(with: try #require(SharedEvents.mouse(.leftMouseDown, at: inside, in: row)))
        #expect(recorder.mouseDowns == 1)
        row.mouseUp(with: try #require(SharedEvents.mouse(.leftMouseUp, at: inside, in: row)))
        row.mouseUp(with: try #require(SharedEvents.mouse(.leftMouseUp, at: inside, in: row, clicks: 2)))
        #expect(clicks == 1, "a double click without a handler does nothing more")
        row.onDoubleClick = { doubles += 1 }
        row.mouseUp(with: try #require(SharedEvents.mouse(.leftMouseUp, at: inside, in: row, clicks: 2)))
        row.mouseUp(with: try #require(SharedEvents.mouse(.leftMouseUp, at: NSPoint(x: 500, y: 5), in: row)))
        #expect(doubles == 1)
        #expect(clicks == 1)
    }

    @Test func rowViewKeyboardAndAccessibility() throws {
        UITestSupport.bootstrap()
        let row = RowView(frame: .zero)
        let recorder = SharedResponderRecorder()
        row.nextResponder = recorder
        #expect(!row.isAccessibilityElement())
        #expect(row.accessibilityRole() == .group)
        #expect(!row.accessibilityPerformPress())
        #expect(!row.acceptsFirstResponder)
        row.keyDown(with: try #require(SharedEvents.key(" ", code: KeyPress.space)))
        var clicks = 0
        row.onClick = { clicks += 1 }
        row.keyDown(with: try #require(SharedEvents.key(" ", code: KeyPress.space)))
        row.keyDown(with: try #require(SharedEvents.key(" ", code: KeyPress.space, modifiers: .command)))
        #expect(clicks == 1)
        #expect(recorder.keys == [KeyPress.space, KeyPress.space])
        #expect(row.isAccessibilityElement())
        #expect(row.accessibilityRole() == .button)
        #expect(row.accessibilityPerformPress())
        #expect(clicks == 2)
        #expect(row.acceptsFirstResponder == NSApp.isFullKeyboardAccessEnabled)
    }

    @Test func fillViewDrawsSquareRoundedAndBordered() {
        let view = FillView(color: Theme.separator)
        view.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        renderBoth(view)
        view.cornerRadius = 4
        view.borderColor = Theme.accent
        renderBoth(view)
        view.color = Theme.inset
        view.viewDidChangeEffectiveAppearance()
        #expect(view.color === Theme.inset)
    }

    @Test func wrapRowArrangesItemsOntoLines() {
        let sizes = [NSSize(width: 50, height: 20), NSSize(width: 50, height: 24), NSSize(width: 80, height: 20)]
        let wide = WrapRow.arrange(sizes, width: 500, spacing: 6)
        #expect(wide.frames.map(\.minY) == [0, 0, 0])
        #expect(wide.height == 24)
        let narrow = WrapRow.arrange(sizes, width: 110, spacing: 6)
        #expect(narrow.frames.map(\.minX) == [0, 56, 0])
        #expect(narrow.frames[2].minY == 30)
        #expect(narrow.height == 50)
        let clipped = WrapRow.arrange([NSSize(width: 300, height: 10)], width: 100, spacing: 6)
        #expect(clipped.frames[0].width == 100)
        #expect(WrapRow.arrange([], width: 100, spacing: 6).height == 0)
    }

    @Test func wrapRowLaysOutVisibleItemsAndReportsItsHeight() {
        let buttons = (0..<4).map { PartsButton.quiet("Button \($0)") {} }
        buttons[3].isHidden = true
        let row = WrapRow(buttons, spacing: 4)
        #expect(row.isFlipped)
        let unbounded = row.intrinsicContentSize
        #expect(unbounded.height == 22)
        #expect(unbounded.width == NSView.noIntrinsicMetric)
        row.frame = NSRect(x: 0, y: 0, width: 120, height: 100)
        row.layout()
        row.layout()
        #expect(buttons[1].frame.minY > 0)
        #expect(row.intrinsicContentSize.height > 22)
    }

    @Test func keyPressReadsActivationModifiersAndArrows() throws {
        #expect(KeyPress.isActivation(try #require(SharedEvents.key(" ", code: KeyPress.space))))
        #expect(KeyPress.isActivation(try #require(SharedEvents.key("\r", code: KeyPress.returnKey))))
        #expect(!KeyPress.isActivation(try #require(SharedEvents.key("a", code: 0))))
        #expect(KeyPress.isPlain(try #require(SharedEvents.key("a", code: 0))))
        #expect(!KeyPress.isPlain(try #require(SharedEvents.key("a", code: 0, modifiers: .option))))
        let steps = try [KeyPress.leftArrow, KeyPress.upArrow, KeyPress.rightArrow, KeyPress.downArrow, 0].map {
            KeyPress.arrowStep(try #require(SharedEvents.key("x", code: $0)))
        }
        #expect(steps == [-1, -1, 1, 1, nil])
        #expect(KeyPress.keypadEnter == 76)
    }

    @Test func deckLabelShowsItsTextAsTooltipOnlyWhenTruncated() {
        let label = Deck.label("A fairly long label that will not fit")
        label.frame = NSRect(x: 0, y: 0, width: 30, height: 16)
        label.layout()
        #expect(label.toolTip == label.stringValue)
        label.frame.size.width = 1_000
        label.layout()
        #expect(label.toolTip == nil)
        label.toolTip = "Own"
        label.frame.size.width = 30
        label.layout()
        #expect(label.toolTip == "Own")
    }

    @Test func wrappingLabelFollowsItsWidth() {
        let label = Deck.wrapping("Some words that wrap", characterWrap: true)
        #expect(label.lineBreakMode == .byCharWrapping)
        label.frame = NSRect(x: 0, y: 0, width: 80, height: 40)
        label.layout()
        #expect(label.preferredMaxLayoutWidth == 80)
        #expect(Deck.wrapping("x").lineBreakMode == .byWordWrapping)
    }

    @Test func otherTitledWindowsKeepTheAppInTheDock() {
        UITestSupport.bootstrap()
        let closing = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let hidden = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        closing.isReleasedWhenClosed = false
        hidden.isReleasedWhenClosed = false
        #expect(!ActivationPolicyCoordinator.keepsRegular([closing, hidden], closing: closing))
        #expect(!ActivationPolicyCoordinator.keepsRegular([], closing: nil))
    }

    @Test func stackHugsItsContentWeakly() {
        let stack = NSStackView(views: [])
        stack.hugsContent()
        let weak = stack.constraints.filter { $0.priority.rawValue == 200 && $0.constant == 0 }
        #expect(weak.count == 2)
    }
}
