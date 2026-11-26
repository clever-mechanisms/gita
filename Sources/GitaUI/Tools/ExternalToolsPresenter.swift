import Foundation
import GitaCore

struct ExternalToolsPresenter: Sendable {
    func presets(for _: ExternalToolKind) -> [ExternalToolPreset] {
        ExternalToolPreset.allCases
    }

    func installedBadge(_ detection: ExternalToolDetection?) -> String {
        switch detection {
        case nil: String(localized: "Checking…")
        case .installed: String(localized: "Installed")
        case .notInstalled: String(localized: "Not installed")
        }
    }

    func executable(_ selection: ExternalToolSelection, detection: ExternalToolDetection?) -> String {
        if selection.preset == .custom { return selection.customExecutable }
        if case .installed(let path) = detection { return path }
        return installedBadge(detection)
    }

    func arguments(_ selection: ExternalToolSelection, kind: ExternalToolKind) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(selection.arguments(for: kind)) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    func validation(
        _ selection: ExternalToolSelection, kind: ExternalToolKind,
        detection: ExternalToolDetection?
    ) -> String? {
        guard detection != nil || selection.preset == .custom else { return installedBadge(nil) }
        var paths = ["$LEFT": "left.txt", "$RIGHT": "right.txt"]
        if kind == .merge {
            paths["$BASE"] = "base.txt"
            paths["$MERGED"] = "result.txt"
        }
        do {
            _ = try ExternalToolLauncher.resolveCommand(
                selection: selection, kind: kind, paths: paths,
                detector: detection ?? .notInstalled)
            return nil
        } catch { return error.localizedDescription }
    }

    func banner(_ state: ExternalToolLaunchState) -> String {
        switch state {
        case .idle: ""
        case .launching: String(localized: "Test in progress…")
        case .launched(let tool): String(localized: "\(tool) completed the test.")
        case .failed(let reason): reason
        }
    }
}
