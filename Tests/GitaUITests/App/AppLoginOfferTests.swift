import AppKit
import Testing

@testable import GitaUI

/// The Open at Login offer's own timing: it waits out the delay in a settled window, and anything that hides it
/// meanwhile wins.
@MainActor
@Suite("App: the login offer")
struct AppLoginOfferTests {
    @MainActor private final class Fixture {
        let controller = LoginOfferController()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var allowed = true

        init(delay: Duration) {
            controller.delay = delay
            controller.canOffer = { [weak self] in self?.allowed ?? false }
            controller.container = { [weak self] in self?.content }
        }
    }

    @Test func theOfferAppearsAfterTheDelayOnce() async {
        let fixture = Fixture(delay: .zero)
        fixture.controller.update()
        #expect(!fixture.controller.isShown)
        await appWaitUntil { fixture.controller.isShown }
        let offer = fixture.controller.offer
        #expect(offer?.superview === fixture.content)
        fixture.controller.update()
        #expect(fixture.controller.offer === offer)
        fixture.controller.hide()
        #expect(!fixture.controller.isShown)
        #expect(offer?.superview == nil)
    }

    @Test func anOfferThatMayNotShowStaysHidden() async throws {
        let fixture = Fixture(delay: .milliseconds(20))
        fixture.allowed = false
        fixture.controller.update()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!fixture.controller.isShown)
        // Allowed when asked, but no longer when the delay is over.
        fixture.allowed = true
        fixture.controller.update()
        fixture.allowed = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(!fixture.controller.isShown)
        // The wait ended, so asking again starts a new one.
        fixture.allowed = true
        fixture.controller.update()
        await appWaitUntil { fixture.controller.isShown }
    }

    @Test func hidingDuringTheWaitCancelsIt() async throws {
        let fixture = Fixture(delay: .milliseconds(50))
        fixture.controller.update()
        fixture.controller.hide()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fixture.controller.isShown)
        #expect(fixture.content.subviews.isEmpty)
        // An update after a disallowed check hides at once too.
        fixture.controller.update()
        fixture.allowed = false
        fixture.controller.update()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fixture.controller.isShown)
    }
}
