import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
struct SmartDiffInteractionTests {
    @Test func modeGroupsExposeTheSelectedButton() throws {
        let control = SmartDiffFacade.shared.makeNarrativeOrderModeControl(mode: .pathTree)
        let orderGroup = try checkGroup(in: control, titles: ["Narrative", "Path", "A–Z"], selected: "Path")
        #expect(orderGroup.accessibilityIdentifier() == "smartdiff.order.mode")
        #expect(control.accessibilityIdentifier() != "smartdiff.order.mode")
        let url = try #require(URL(string: "https://example.test"))
        let presenter = VisualPreviewDiffPresenter(productionURL: url, previewURL: url)
        let toolbar = VisualPreviewToolbar(presenter)
        presenter.setMode(.onionSkin)
        toolbar.refresh()
        _ = try checkGroup(in: toolbar, titles: ["Swipe", "Onion", "Side by Side"], selected: "Onion")
    }

    @discardableResult
    private func checkGroup(in view: NSView, titles: [String], selected: String) throws -> NSStackView {
        let stacks = SharedFixtures.descendants(view, of: NSStackView.self)
        let group = try #require(stacks.first { $0.accessibilityRole() == .radioGroup })
        #expect(group.isAccessibilityElement())
        #expect(group.accessibilityLabel()?.isEmpty == false)
        let buttons = group.arrangedSubviews.compactMap { $0 as? PartsButton }
        #expect(buttons.compactMap { $0.accessibilityLabel() } == titles)
        for button in buttons {
            let active = button.accessibilityLabel() == selected
            #expect(button.fixedHeight == 22 && button.background == (active ? .selected : .quiet))
            #expect(button.accessibilityValue() as? String == (active ? "selected" : nil))
        }
        return group
    }

    @Test func sparklineActivationAndEscape() throws {
        let commit = GitCommit(id: "1", parents: [], subject: "", author: "A", date: Date())
        var jumps = 0
        let view = SmartDiffFacade.shared.makeVelocitySparklineView(commits: [commit]) { _ in jumps += 1 }
        let recorder = SharedResponderRecorder()
        view.nextResponder = recorder
        let enter = try #require(SharedEvents.key("\r", code: KeyPress.returnKey))
        let space = try #require(SharedEvents.key(" ", code: KeyPress.space))
        let escape = try #require(SharedEvents.key("", code: KeyPress.escape))
        view.keyDown(with: enter)
        view.keyDown(with: space)
        #expect(jumps == 0 && view.presenter.activeBucket == nil)
        view.keyDown(with: try #require(SharedEvents.key("", code: KeyPress.rightArrow)))
        view.keyDown(with: space)
        #expect(jumps == 1)
        view.keyDown(with: escape)
        #expect(view.presenter.activeBucket == nil && recorder.keys.isEmpty)
        view.presenter.hover(at: 0)
        view.keyDown(with: escape)
        #expect(view.presenter.activeBucket == nil && recorder.keys.isEmpty)
        view.keyDown(with: escape)
        #expect(recorder.keys == [KeyPress.escape])
    }

    @Test func sparklineDrawsEmptyCaptionOnlyForEmptyData() async throws {
        let view = VelocitySparklineOverlayView(frame: CGRect(x: 0, y: 0, width: 240, height: 64))
        let spinner = try #require(view.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        let idle = try drawing(view)
        view.presenter.setLoading()
        #expect(view.presenter.state == .loading && spinner.isHidden)
        #expect(try drawing(view) == idle)
        #expect(await SharedFixtures.waitUntil(seconds: 2) { !spinner.isHidden })
        view.update([])
        #expect(view.presenter.state == .empty && spinner.isHidden)
        #expect(try drawing(view) != idle)
        #expect(view.focusRingMaskBounds == view.bounds)
    }

    @Test func cancelOperationForwardsToNextResponderWhenNothingExpanded() {
        @MainActor
        final class CancelTarget: NSResponder {
            var cancelCount = 0
            override func cancelOperation(_: Any?) { cancelCount += 1 }
        }
        let controller = SmartDiffFacade.shared.makeSmartDiffViewController()
        controller.loadView()
        let target = CancelTarget()
        controller.nextResponder = target
        controller.cancelOperation(nil)
        #expect(target.cancelCount == 1)
    }

    private func drawing(_ view: NSView) throws -> Data {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
