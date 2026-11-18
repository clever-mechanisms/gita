import AppKit
import Foundation

@testable import GitaCore
@testable import GitaUI

/// An `AppOpener` that finds the apps it is given and records what would have opened; nothing opens.
@MainActor
final class ActionsRecordingOpener {
    enum Call: Equatable {
        case open(documents: [URL], app: URL)
        case launch(app: URL, arguments: [String], newInstance: Bool)
        case reveal([URL])
        case builtInTerminal(directory: URL, script: URL?)
    }

    var apps: [String: URL]
    private(set) var calls: [Call] = []
    let events = AgentsEvents<Call>()

    init(apps: [String: URL] = [:]) { self.apps = apps }

    var opener: AppOpener {
        AppOpener(
            locate: { [weak self] in self?.apps[$0] },
            open: { [weak self] documents, app, _ in self?.record(.open(documents: documents, app: app)) },
            openApplication: { [weak self] app, configuration in
                self?.record(
                    .launch(
                        app: app, arguments: configuration.arguments,
                        newInstance: configuration.createsNewApplicationInstance))
            },
            reveal: { [weak self] in self?.record(.reveal($0)) },
            openBuiltInTerminal: { [weak self] in self?.record(.builtInTerminal(directory: $0, script: $1)) })
    }

    private func record(_ call: Call) {
        calls.append(call)
        events.yield(call)
    }
}

/// Repository models for menu and confirmation tests, on real temporary repositories.
@MainActor
enum ActionsModels {
    /// A model showing `repository`, with its Git service and snapshot, and its own defaults.
    static func open(_ repository: TemporaryRepository, defaults: UserDefaults) async throws -> AppModel {
        let service = GitService(root: repository.url)
        let model = AppModel(defaults: defaults)
        model.service = service
        model.root = repository.url
        model.snapshot = try await service.snapshot()
        return model
    }

    /// A fake app bundle with this identifier, so `Bundle(url:)` reads it like an installed app.
    static func app(_ bundleIdentifier: String, named name: String, in folder: URL) throws -> URL {
        let app = folder.appendingPathComponent(name + ".app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleIdentifier, "CFBundleName": name]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}

/// An alert presenter that records each alert and answers with its second button (Cancel); no alert is ever shown.
@MainActor
final class ActionsRecordingPresenter {
    private(set) var alerts: [NSAlert] = []

    var presenter: AlertPresenter {
        AlertPresenter { [weak self] alert, _, completion in
            self?.alerts.append(alert)
            completion(.alertSecondButtonReturn)
        }
    }
}
