import AppKit
import Testing

@testable import GitaUI

@MainActor
private final class ClampStubWindow: NSWindow {
    var stubMiniaturized = false
    var stubInLiveResize = false
    var stubVisible = false

    override var isMiniaturized: Bool { stubMiniaturized }
    override var inLiveResize: Bool { stubInLiveResize }
    override var isVisible: Bool { stubVisible || super.isVisible }
}

@MainActor
@Suite("Window frame clamping")
struct WindowFrameClampTests {
    @Test func selectsLargestIntersectionIncludingNegativeOrigins() {
        let left = NSRect(x: -1_440, y: 0, width: 1_440, height: 900)
        let primary = NSRect(x: 0, y: 25, width: 1_728, height: 1_055)
        let below = NSRect(x: 0, y: -1_080, width: 1_920, height: 1_080)
        let screens = [left, primary, below]

        // Mostly on negative-origin left display, overhanging past its left and top edges.
        let straddlingLeft = NSRect(x: -1_500, y: 500, width: 800, height: 500)
        #expect(WindowFrameClamp.bestVisibleFrame(for: straddlingLeft, screens: screens) == left)
        let clampedLeft = WindowFrameClamp.clamped(straddlingLeft, screens: screens)
        #expect(clampedLeft == NSRect(x: -1_440, y: 400, width: 800, height: 500))

        // Straddling left and primary, with larger area on primary.
        let mostlyPrimary = NSRect(x: -100, y: 100, width: 800, height: 600)
        #expect(WindowFrameClamp.bestVisibleFrame(for: mostlyPrimary, screens: screens) == primary)

        // Negative Y display below primary.
        let straddlingBelow = NSRect(x: 200, y: -1_200, width: 900, height: 600)
        #expect(WindowFrameClamp.bestVisibleFrame(for: straddlingBelow, screens: screens) == below)
        let clampedBelow = WindowFrameClamp.clamped(straddlingBelow, screens: screens)
        #expect(clampedBelow == NSRect(x: 200, y: -1_080, width: 900, height: 600))
    }

    @Test func fallsBackAndRespectsMinSizeAndInvalidBounds() {
        let primary = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let secondary = NSRect(x: 1_200, y: 0, width: 1_000, height: 700)
        let offscreen = NSRect(x: 5_000, y: 5_000, width: 400, height: 300)

        // Completely off-screen uses preferred display, else first screen.
        let withPreferred = WindowFrameClamp.clamped(offscreen, screens: [primary, secondary], preferred: secondary)
        #expect(withPreferred == NSRect(x: 1_800, y: 400, width: 400, height: 300))
        let withoutPreferred = WindowFrameClamp.clamped(offscreen, screens: [primary, secondary])
        #expect(withoutPreferred == NSRect(x: 800, y: 500, width: 400, height: 300))

        // Empty screens or empty visibleFrame leaves the frame unchanged.
        #expect(WindowFrameClamp.clamped(offscreen, screens: []) == offscreen)
        #expect(WindowFrameClamp.clamped(offscreen, in: .zero) == offscreen)

        // Min size expands small frames up to visibleFrame, and shrinks oversized frames to visibleFrame.
        let tiny = NSRect(x: 50, y: 50, width: 200, height: 150)
        let expanded = WindowFrameClamp.clamped(tiny, in: primary, minSize: NSSize(width: 600, height: 400))
        #expect(expanded == NSRect(x: 50, y: 50, width: 600, height: 400))
        let oversized = NSRect(x: 0, y: 0, width: 2_000, height: 1_500)
        let shrunk = WindowFrameClamp.clamped(oversized, in: primary, minSize: NSSize(width: 1_400, height: 900))
        #expect(shrunk == primary)
    }

    @Test func skipsFullScreenMiniaturizedAndLiveResizingWindows() {
        UITestSupport.bootstrap()
        let originalScreens = WindowFrameClamp.screenVisibleFrames
        defer { WindowFrameClamp.screenVisibleFrames = originalScreens }
        WindowFrameClamp.screenVisibleFrames = { [NSRect(x: 0, y: 0, width: 800, height: 600)] }

        let offscreen = NSRect(x: 2_400, y: 1_500, width: 500, height: 400)

        let fullScreen = ClampStubWindow(
            contentRect: offscreen, styleMask: [.titled, .fullScreen], backing: .buffered, defer: true)
        fullScreen.isReleasedWhenClosed = false
        fullScreen.setFrame(offscreen, display: false)
        WindowFrameClamp.clamp(fullScreen)
        #expect(fullScreen.frame == offscreen)

        let miniaturized = ClampStubWindow(
            contentRect: offscreen, styleMask: [.titled, .miniaturizable], backing: .buffered, defer: true)
        miniaturized.isReleasedWhenClosed = false
        miniaturized.setFrame(offscreen, display: false)
        miniaturized.stubMiniaturized = true
        WindowFrameClamp.clamp(miniaturized)
        #expect(miniaturized.frame == offscreen)

        let liveResize = ClampStubWindow(
            contentRect: offscreen, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        liveResize.isReleasedWhenClosed = false
        liveResize.setFrame(offscreen, display: false)
        liveResize.stubInLiveResize = true
        WindowFrameClamp.clamp(liveResize)
        #expect(liveResize.frame == offscreen)
    }

    @Test func clampsTrackedVisibleWindowsOnScreenParameterChange() {
        UITestSupport.bootstrap()
        let originalScreens = WindowFrameClamp.screenVisibleFrames
        defer { WindowFrameClamp.screenVisibleFrames = originalScreens }
        let smallerScreen = NSRect(x: 0, y: 25, width: 1_000, height: 700)
        WindowFrameClamp.screenVisibleFrames = { [smallerScreen] }

        let window = ClampStubWindow(
            contentRect: NSRect(x: 2_000, y: 1_000, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 500, height: 350)
        window.setFrame(NSRect(x: 2_000, y: 1_000, width: 600, height: 400), display: false)
        window.stubVisible = true
        WindowFrameClamp.track(window)

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        #expect(smallerScreen.contains(window.frame))
        #expect(window.frame.width == 600)
        #expect(window.frame.height == 400)
    }

    @Test func auxiliaryShowClampsAndTracksAndPaletteClampsOverEdgeParent() {
        UITestSupport.bootstrap()
        let originalScreens = WindowFrameClamp.screenVisibleFrames
        defer { WindowFrameClamp.screenVisibleFrames = originalScreens }
        let left = NSRect(x: -1_280, y: 0, width: 1_280, height: 800)
        let primary = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        WindowFrameClamp.screenVisibleFrames = { [left, primary] }

        var policies: [NSApplication.ActivationPolicy] = []
        let window = NSWindow(
            contentRect: NSRect(x: 3_000, y: 2_000, width: 500, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let coordinator = ActivationPolicyCoordinator(
            setPolicy: { policies.append($0) }, activate: {}, windows: { [window] })

        AuxiliaryWindowActivation.show(window, coordinator: coordinator)
        #expect(policies == [.regular])
        #expect(left.contains(window.frame) || primary.contains(window.frame))

        AuxiliaryWindowActivation.closing(nil, coordinator: coordinator)
        #expect(policies == [.regular])
        AuxiliaryWindowActivation.closing(window, coordinator: coordinator)
        #expect(policies == [.regular, .accessory])

        // Palette over a parent near the top-left edge of a negative-origin display clamps inside that display.
        let edgeParent = NSRect(x: -1_300, y: 400, width: 500, height: 450)
        let paletteFrame = PaletteController.frame(over: edgeParent, screens: [left, primary], preferred: left)
        #expect(left.contains(paletteFrame))
        #expect(paletteFrame.size == PaletteController.size)
    }
}
