import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// Helpers the sheet tests share: polling waits, view lookup by accessibility identifier, control driving and
/// fixtures for the Git model values the sheets review.
@MainActor
enum SheetsSupport {
    struct TimedOut: Error {}

    /// Waits until `condition` holds, yielding to let the sheet's tasks run; fails after a few seconds.
    static func wait(
        _ condition: @MainActor () -> Bool, timeout: Duration = .seconds(120),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for a sheet condition", sourceLocation: sourceLocation)
                throw TimedOut()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lets queued main-actor work run without waiting for a condition.
    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// The first view under `root` (inclusive) whose accessibility identifier is `id`.
    static func view<T: NSView>(_ id: String, in root: NSView?, as _: T.Type = T.self) -> T? {
        guard let root else { return nil }
        if root.accessibilityIdentifier() == id, let match = root as? T { return match }
        for child in root.subviews {
            if let match = view(id, in: child, as: T.self) { return match }
        }
        return nil
    }

    static func require<T: NSView>(
        _ id: String, in window: NSWindow?, as type: T.Type = T.self, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> T {
        try #require(view(id, in: window?.contentView, as: type), sourceLocation: sourceLocation)
    }

    /// All views under `root` of type `T`.
    static func views<T: NSView>(in root: NSView?, of _: T.Type) -> [T] {
        guard let root else { return [] }
        return ([root as? T].compactMap { $0 }) + root.subviews.flatMap { views(in: $0, of: T.self) }
    }

    /// Chooses an item of a popup and sends its action, as a click would.
    static func choose(_ index: Int, in picker: NSPopUpButton) {
        picker.selectItem(at: index)
        picker.sendAction(picker.action, to: picker.target)
    }

    /// Types `text` into a field and tells its delegate, as editing would.
    static func type(_ text: String, into field: NSTextField) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    /// Replaces a text view's contents and tells its delegate.
    static func type(_ text: String, into editor: NSTextView) {
        editor.string = text
        editor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: editor))
    }

    /// Starts a sheet's first read as presenting it would, without ordering the window on screen.
    static func present(_ controller: ReviewSheetController) {
        UITestSupport.bootstrap()
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    }

    nonisolated static func commit(_ id: String, subject: String = "Subject") -> GitCommit {
        GitCommit(
            id: id, parents: [], subject: subject, author: "Tester", email: "tester@example.invalid",
            date: Date(timeIntervalSince1970: 1_700_000_000))
    }

    nonisolated static func objectID(_ seed: Character) -> String { String(repeating: seed, count: 40) }
}

/// An error with a fixed message.
struct SheetsFailure: LocalizedError {
    let message: String
    init(_ message: String = "Sheet test failure") { self.message = message }
    var errorDescription: String? { message }
}

/// Answers discard prompts without a run loop, recording what was asked.
@MainActor
final class SheetsAlertRecorder {
    private(set) var alerts: [NSAlert] = []
    /// Index of the button to answer with; nil keeps the prompt open until `answer` is called.
    var response: Int? = 0
    private var pending: (@MainActor (NSApplication.ModalResponse) -> Void)?

    func install(on controller: ReviewSheetController) {
        controller.presentAlert = { [weak self] alert, _, handler in
            guard let self else { return }
            self.alerts.append(alert)
            if let response = self.response {
                handler(Self.modal(response))
            } else {
                self.pending = handler
            }
        }
    }

    var hasPending: Bool { pending != nil }

    func answer(_ index: Int) {
        let handler = pending
        pending = nil
        handler?(Self.modal(index))
    }

    private static func modal(_ index: Int) -> NSApplication.ModalResponse {
        NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }
}

/// A temporary repository with a `GitService` over it, plus helpers to build common histories.
@MainActor
final class SheetsRepository {
    let repository: TemporaryRepository
    let service: GitService
    var url: URL { repository.url }

    init() throws {
        repository = try TemporaryRepository()
        service = GitService(root: repository.url)
    }

    @discardableResult func commit(_ path: String, _ contents: String, message: String) throws -> String {
        try repository.commit(path, contents, message: message)
    }

    func head() throws -> String {
        try repository.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func exists(_ reference: String) -> Bool {
        (try? repository.git("rev-parse", "--verify", "--quiet", reference)) != nil
    }

    func references() async throws -> [GitReference] { try await service.snapshot().references }

    func gitCommit(_ id: String) async throws -> GitCommit { try await service.commitDetails(ref: id).commit }
}

/// A flag a test flips while a sheet's closure reads it.
@MainActor
final class SheetsToggle {
    var isOn: Bool
    init(_ isOn: Bool) { self.isOn = isOn }
}
