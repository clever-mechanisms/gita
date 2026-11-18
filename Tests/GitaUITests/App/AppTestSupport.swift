import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// A scratch settings domain, removed when released.
final class AppTestDefaults {
    let name = "GitaUITests.App.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name) ?? .standard
        // Nothing in a test reaches GitHub, Vercel or Orca on a timer.
        defaults.set(false, forKey: Preference.providerRefresh.rawValue)
    }

    deinit { defaults.removePersistentDomain(forName: name) }
}

/// Alerts shown through an `AlertPresenter`, answered by the test.
@MainActor
final class AppRecordingAlerts {
    private(set) var alerts: [NSAlert] = []
    /// The app's own sheets begun through the presenter (Fetch, Pull, Push).
    private(set) var sheets: [NSWindow] = []
    private var completions: [AlertPresenter.Completion] = []

    var presenter: AlertPresenter {
        var presenter = AlertPresenter { [weak self] alert, _, completion in
            self?.alerts.append(alert)
            self?.completions.append(completion)
        }
        presenter.beginSheet = { [weak self] sheet, _, completion in
            self?.sheets.append(sheet)
            self?.completions.append(completion)
        }
        return presenter
    }

    /// The views of `type` in the last sheet, in order.
    func sheetViews<View: NSView>(_ type: View.Type) -> [View] {
        Self.views(of: type, in: sheets.last?.contentView)
    }

    var last: NSAlert? { alerts.last }

    /// The text fields of the last alert's accessory view, in order.
    var fields: [NSTextField] {
        (last.map { Self.views(of: NSTextField.self, in: $0.accessoryView) } ?? []).filter(\.isEditable)
    }

    func popUps<View: NSView>(_ type: View.Type) -> [View] {
        last.map { Self.views(of: type, in: $0.accessoryView) } ?? []
    }

    /// Answers the oldest unanswered alert.
    func answer(_ response: NSApplication.ModalResponse = .alertFirstButtonReturn) {
        guard !completions.isEmpty else { return }
        completions.removeFirst()(response)
    }

    static func views<View: NSView>(of type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        let own = (root as? View).map { [$0] } ?? []
        return own + root.subviews.flatMap { views(of: type, in: $0) }
    }
}

/// A command runner for gh, vercel and orca that runs nothing: every command fails as not installed.
struct AppUnavailableRunner: CommandRunning {
    func run(
        executable: String, arguments _: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
    ) async throws -> CommandResult {
        throw CommandError.executableNotFound(executable)
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes (for Git work that runs in tasks).
@MainActor
func appWaitUntil(
    timeout: Duration = .seconds(60), _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for a condition", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

extension AppModel {
    /// A model that reaches no provider CLI, notification, avatar download or real commit draft folder.
    static func appTestModel(defaults: UserDefaults, alerts: AlertPresenter, drafts: URL) -> AppModel {
        let runner = AppUnavailableRunner()
        let dependencies = AppModelDependencies(
            vercelActions: VercelActionService(runner: runner), lookUpAvatars: { _, _, _ in },
            notifyProvider: { _ in }, notifyVercelAlert: { _, _, _ in },
            openCommitDraft: { try CommitMessageDraft.open(root: $0, gitDirectory: $1, in: drafts) })
        return AppModel(
            defaults: defaults, providers: ProviderService(runner: runner), alerts: alerts,
            dependencies: dependencies)
    }
}

/// A value a test's recording closures change.
@MainActor
final class AppBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
