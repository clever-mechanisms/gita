import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// The panel's views drawn and driven offscreen: rows of every kind, chips, pills and the window.
@MainActor
@Suite struct MenuBarPanelViewTests {
    typealias MF = MenuBarFixtures

    private func hosted(_ view: NSView) -> NSWindow {
        UITestSupport.bootstrap()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 200), styleMask: [.borderless],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func drawn(_ row: PanelRow) -> PanelRowView {
        let view = PanelRowView(row, width: Theme.panelWidth)
        _ = hosted(view)
        view.layout()
        UITestSupport.render(view)
        return view
    }

    private var chip: PanelChip { PanelChip(title: "Open ↗", style: .accent, action: .openRepository, label: "Open") }

    @Test func captionsMessagesAndSummariesLayOutAndDraw() {
        let header = drawn(PanelRow(id: "h", kind: .header, title: "Agents", count: "2"))
        #expect(header.accessibilityRole() == .staticText)
        #expect(header.isAccessibilityElement())
        #expect(header.toolTip == nil)
        #expect(PanelRowView.caption("Agents", count: "2", color: Theme.text).string == "AGENTS  2")
        #expect(PanelRowView.caption("Agents", count: nil, color: Theme.text).string == "AGENTS")

        let message = drawn(
            PanelRow(id: "m", kind: .message, lead: .symbol("checkmark.circle", .tertiary), title: "Nothing needs you"))
        #expect(message.textRight == Theme.panelWidth - 16)
        _ = drawn(PanelRow(id: "m2", kind: .message, title: "Nothing new"))

        let summary = drawn(
            PanelRow(
                id: "idle", kind: .summary, lead: .chevron(expanded: true), title: "Idle · app", count: "3",
                disclosure: .expanded, action: .toggle("idle")))
        #expect(summary.accessibilityValue() as? String == "Expanded")
        #expect(summary.accessibilityRole() == .button)
        #expect(summary.textRight < Theme.panelWidth - 16)
        let closed = drawn(
            PanelRow(id: "idle2", kind: .summary, lead: .chevron(expanded: false), disclosure: .collapsed))
        #expect(closed.accessibilityValue() as? String == "Collapsed")
    }

    @Test func itemsAndLinesPlaceChipsAndTheHoverChip() {
        var row = PanelRow(
            id: "i", kind: .line, lead: .mark(.init(tool: .codex, state: .working)), title: "app",
            subtitle: "Account switcher", subtitleTool: .codex, time: "5m", chips: [chip], action: .openRepository,
            label: "app", toolTip: "main")
        row.hoverChip = PanelChip(title: "", symbol: "macwindow", action: .openRepository, label: "Show")
        let view = drawn(row)
        #expect(view.chipViews[0].frame.maxX == Theme.panelWidth - 16)
        #expect(view.textRight < view.chipViews[0].frame.minX)
        #expect(view.hoverChipView?.isHidden == true)
        view.isSelected = true
        #expect(view.hoverChipView?.isHidden == false)
        UITestSupport.render(view)
        view.viewDidChangeEffectiveAppearance()
        #expect(view.toolTip == "app\nCodex · Account switcher\nmain")

        let single = drawn(
            PanelRow(
                id: "j", kind: .item, lead: .symbol("globe", .accentText), title: "Preview ready", suffix: "app",
                hoverChip: PanelChip(title: "", symbol: "doc.on.doc", action: .copy("x"), label: "Copy"),
                action: .copy("x")))
        #expect(single.textRight < Theme.panelWidth - 12)
        single.isHovered = true
        UITestSupport.render(single)
        single.viewDidChangeEffectiveAppearance()
        _ = drawn(
            PanelRow(id: "two", kind: .item, title: "octo opened #7", subtitle: "Add things", time: "3h"))
        let plain = drawn(PanelRow(id: "k", kind: .item, title: "Tiny"))
        #expect(!plain.accessibilityPerformPress())
        plain.mouseDown(with: MenuBarPanelControllerTests.key(0))
        #expect(!plain.pressed)
    }

    @Test func anAttentionCardHasItsDiscTextAndChip() {
        let row = PanelRow(
            id: "a", kind: .attention, lead: .symbol("eye", .needsInputText), title: "Review requested",
            subtitle: "storefront · #482 Checkout", time: "1h",
            chips: [PanelChip(title: "Review", action: .openRepository, label: "Open Pull Request")],
            action: .openRepository)
        let view = drawn(row)
        #expect(view.frame.height == 52)
        let chip = view.chipViews[0]
        #expect(chip.frame.maxX == Theme.panelWidth - 18)
        #expect(chip.frame.midY == 24)
        // The time is beside the title: only the chip takes room from the text.
        #expect(view.textRight == chip.frame.minX - 6)
        #expect(view.toolTip == "Review requested\nstorefront · #482 Checkout")
        #expect(view.accessibilityRole() == .button)
        view.isSelected = true
        UITestSupport.render(view)
        _ = drawn(PanelRow(id: "c", kind: .attention, lead: .symbol("xmark", .failure), title: "Conflicts"))
    }

    @Test func aWorkspaceCardLaysOutItsStateAndWrappingPills() throws {
        let names = (1...12).map { "repository-\($0)" }
        var pills = names.map { PanelPill(id: $0, title: $0, action: .openRepository, toolTip: $0 + "\nmain") }
        pills[0].mark = .agent(.init(tool: .claudeCode, state: .needsInput))
        pills[0].tinted = true
        pills[1].mark = .checks(.failure)
        pills[1].counts = "↑2 ↓1"
        pills = pills.map { pill in
            var pill = pill
            pill.width = PanelPillButton.width(pill)
            return pill
        }
        let row = PanelRow(
            id: "w", kind: .workspace, lead: .symbol(Deck.workspaceSymbol, .accentText), title: "Gitā",
            status: "In front", statusColor: .accentText, pills: pills, action: .openWorkspace("w"))
        let view = drawn(row)
        #expect(view.frame.height == row.height)
        #expect(view.toolTip == nil)
        // A group, not a button: its pills are reached one by one.
        #expect(view.accessibilityRole() == .group)
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityLabel() == "Gitā")
        // Its symbol is decoration; the pills are the elements inside it.
        let images = view.subviews.compactMap { $0 as? NSImageView }
        #expect(images.count == 1 && images.allSatisfy { $0.cell?.isAccessibilityElement() == false })
        let pillsView = try #require(view.pillsView)
        #expect(pillsView.frame.origin == NSPoint(x: 20, y: 35))
        #expect(pillsView.frame.maxY == row.height - PanelCard.bottom - PanelCard.workspaceGap)
        let buttons = pillsView.buttons
        #expect(buttons.count == 12)
        // Twelve tabs do not fit on one line, and none leaves the card.
        #expect(Set(buttons.map(\.frame.minY)).count > 1)
        #expect(buttons.allSatisfy { $0.frame.maxX <= PanelCard.pillsWidth })
        #expect(buttons[0].frame.width == pills[0].width)
        #expect(buttons[1].frame.width > PanelPillButton.width(PanelPill(id: "p", title: "repository-2")))
        #expect(buttons[0].toolTip == "repository-1\nmain")
        #expect(buttons[0].accessibilityLabel() == "repository-1, main")
        #expect(buttons[0].accessibilityRole() == .button)
        #expect(buttons[0].hitTest(NSPoint(x: 4, y: 4)) != nil)
        #expect(buttons[0].menu(for: MenuBarPanelControllerTests.key(0)) == nil)
        view.selectedPill = 1
        #expect(buttons.map(\.isChosen).filter { $0 }.count == 1 && buttons[1].isChosen)
        UITestSupport.render(view)
        // The state leaves the name less room.
        #expect(view.textRight < Theme.panelWidth - 20 - PanelRowView.statusWidth("In front"))
    }

    @Test func aClosedWorkspaceIsAnOutlineWithLabelsAndAnOpenChip() throws {
        var pill = PanelPill(id: "dotfiles", title: "dotfiles", mark: .checks(.success), toolTip: "dotfiles")
        pill.width = PanelPillButton.width(pill)
        let row = PanelRow(
            id: "c", kind: .workspace, lead: .symbol(Deck.workspaceSymbol, .tertiary), title: "Open source",
            suffix: "Closed", chips: [PanelChip(title: "Open", action: .openWorkspace("c"), label: "Open")],
            pills: [pill], outlined: true, action: .openWorkspace("c"))
        let view = drawn(row)
        let chip = view.chipViews[0]
        #expect(chip.frame.maxX == Theme.panelWidth - 20)
        #expect(chip.frame.midY == 18)
        let label = try #require(view.pillsView?.buttons.first)
        #expect(label.accessibilityRole() == .staticText)
        // A label takes no clicks: they reach the card.
        #expect(label.hitTest(NSPoint(x: 4, y: 4)) == nil)
        label.performClick(nil)
        view.isHovered = true
        UITestSupport.render(view)
        view.isSelected = true
        UITestSupport.render(view)
    }

    @Test func updatingRebuildsOnlyWhenTheRowChanges() {
        let row = PanelRow(id: "i", kind: .item, title: "app", chips: [chip], action: .openRepository)
        let view = PanelRowView(row, width: Theme.panelWidth)
        let first = view.chipViews.first
        view.update(row)
        #expect(view.chipViews.first === first)
        var next = row
        next.chips = []
        next.kind = .workspace
        next.pills = [PanelPill(id: "p", title: "p", width: 30)]
        view.update(next)
        #expect(view.chipViews.isEmpty)
        #expect(view.pillsView?.buttons.count == 1)
        #expect(view.row == next)
        next.pills = []
        view.update(next)
        #expect(view.pillsView == nil)
    }

    @Test func toolTipJoinsWhatIsKnown() {
        var row = PanelRow(id: "i", kind: .item, title: "app")
        #expect(PanelRowView.toolTip(row) == "app")
        row.subtitleTool = .claudeCode
        #expect(PanelRowView.toolTip(row) == "app\nClaude Code")
        row.subtitle = "main"
        row.toolTip = "#7 Seven"
        #expect(PanelRowView.toolTip(row) == "app\nClaude Code · main\n#7 Seven")
    }

    @Test func chipsSizeThemselvesAndDrawEveryStyle() {
        let styles: [PanelChip.Style] = [.accent, .attention, .quiet, .link, .subtle]
        for style in styles {
            for (title, symbol) in [("Push 2", "arrow.up"), ("", "doc.on.doc"), ("Copy", nil)] as [(String, String?)] {
                let button = PanelChipButton(
                    PanelChip(title: title, symbol: symbol, style: style, action: .openRepository, label: "Chip"))
                let size = button.intrinsicContentSize
                #expect(size.height == 20 && size.width >= 20)
                button.frame = NSRect(origin: .zero, size: size)
                UITestSupport.render(button)
                button.highlight(true)
                UITestSupport.render(button)
                #expect(button.toolTip == "Chip")
            }
        }
        var pressed = 0
        let button = PanelChipButton(chip)
        button.onPress = { pressed += 1 }
        button.performClick(nil)
        #expect(pressed == 1)
    }

    @Test func headerButtonsDrawTheirStates() throws {
        final class Target: NSObject {
            var hits = 0
            @objc func hit() { hits += 1 }
        }
        let target = Target()
        let icon = PanelIconButton(
            symbol: "arrow.clockwise", label: "Refresh", identifier: "refresh", target: target,
            action: #selector(Target.hit))
        icon.frame = NSRect(origin: .zero, size: icon.intrinsicContentSize)
        _ = hosted(icon)
        icon.updateTrackingAreas()
        #expect(icon.trackingAreas.count == 1)
        icon.mouseEntered(with: MenuBarPanelControllerTests.key(0))
        #expect(icon.isHovering)
        UITestSupport.render(icon)
        icon.mouseExited(with: MenuBarPanelControllerTests.key(0))
        #expect(!icon.isHovering)
        icon.performClick(nil)
        #expect(target.hits == 1)
        #expect(icon.accessibilityIdentifier() == "panel.refresh")
    }

    // MARK: Window

    @Test func windowSitsCentredUnderTheItemInsideTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let size = NSSize(width: 300, height: 200)
        let centred = MenuPanelWindow.frame(
            size: size, below: NSRect(x: 490, y: 776, width: 20, height: 24), in: screen)
        #expect(centred == NSRect(x: 350, y: 570, width: 300, height: 200))
        let right = MenuPanelWindow.frame(size: size, below: NSRect(x: 980, y: 776, width: 20, height: 24), in: screen)
        #expect(right.maxX == 992)
        let left = MenuPanelWindow.frame(size: size, below: NSRect(x: 0, y: 776, width: 20, height: 24), in: screen)
        #expect(left.minX == 8)
    }

    @Test func windowFollowsThePanelSizeAndClosesOnce() {
        UITestSupport.bootstrap()
        let controller = MenuPanelController(actions: MenuPanelActions())
        let window = MenuPanelWindow(controller: controller)
        #expect(window.canBecomeKey && !window.canBecomeMain)
        controller.update(MenuPanelState(checkedAt: MF.now))
        controller.onSizeChange?(NSSize(width: Theme.panelWidth, height: 222))
        #expect(window.frame.height == 222)
        var closed = 0
        window.onClose = { closed += 1 }
        window.performClose(nil)
        window.cancelOperation(nil)
        #expect(closed == 0)
        #expect(!window.isShown)
        UITestSupport.render(window.contentView!)

        let item = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        window.show(below: item, size: NSSize(width: Theme.panelWidth, height: 180))
        #expect(window.isShown)
        #expect(item.isHighlighted)
        // Esc first goes back from Activity, then closes the panel.
        controller.show(.activity)
        window.cancelOperation(nil)
        #expect(window.isShown && controller.page == .inbox)
        window.cancelOperation(nil)
        #expect(!window.isShown && !window.isVisible)
        #expect(!item.isHighlighted)
        #expect(closed == 1)
        window.resignKey()
        #expect(closed == 1)
    }
}
