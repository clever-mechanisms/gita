import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
enum TeleportTestSupport {
    static func render(_ view: NSView, width: CGFloat, height: CGFloat) {
        UITestSupport.bootstrap()
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            UITestSupport.render(view)
        }
    }

    static func until(_ check: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !check(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(check())
    }

    static func child(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for child in view.subviews {
            if let found = self.child(id, in: child) { return found }
        }
        return nil
    }

    static func key(_ code: UInt16, text: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code))
    }
}

struct TeleportUIRunner: CommandRunning {
    let response: @Sendable ([String]) async throws -> CommandResult
    func run(
        executable _: String, arguments: [String], directory _: URL?, timeout _: TimeInterval,
        outputLimit _: Int
    ) async throws -> CommandResult {
        try await response(arguments)
    }

    static func result(_ output: String = "", code: Int32 = 0) -> CommandResult {
        .init(stdout: Data(output.utf8), stderr: Data(), exitCode: code)
    }
}
