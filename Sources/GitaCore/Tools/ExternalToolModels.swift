import Foundation

public enum ExternalToolKind: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case diff, merge
}

public enum ExternalToolPreset: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case kaleidoscope, beyondCompare, vsCode, cursor, fileMerge, diffMerge, araxisMerge, p4Merge, custom

    public var displayName: String {
        switch self {
        case .kaleidoscope: String(localized: "Kaleidoscope")
        case .beyondCompare: String(localized: "Beyond Compare")
        case .vsCode: String(localized: "Visual Studio Code")
        case .cursor: String(localized: "Cursor")
        case .fileMerge: String(localized: "FileMerge")
        case .diffMerge: String(localized: "DiffMerge")
        case .araxisMerge: String(localized: "Araxis Merge")
        case .p4Merge: String(localized: "P4Merge")
        case .custom: String(localized: "Custom")
        }
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .kaleidoscope:
            [
                "app.kaleidoscope.v6", "app.kaleidoscope.v5", "app.kaleidoscope.v4",
                "app.kaleidoscope.v3", "com.blackpixel.kaleidoscope",
            ]
        case .beyondCompare: ["com.ScooterSoftware.BeyondCompare"]
        case .vsCode: ["com.microsoft.VSCode"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .fileMerge: ["com.apple.dt.Xcode"]
        case .diffMerge: ["com.sourcegear.DiffMerge"]
        case .araxisMerge: ["com.araxis.merge"]
        case .p4Merge: ["com.perforce.p4merge"]
        case .custom: []
        }
    }

    var embeddedCLI: String {
        switch self {
        case .kaleidoscope: "Contents/MacOS/ksdiff"
        case .beyondCompare: "Contents/MacOS/bcomp"
        case .vsCode: "Contents/Resources/app/bin/code"
        case .cursor: "Contents/Resources/app/bin/cursor"
        case .fileMerge: "Contents/Developer/usr/bin/opendiff"
        case .diffMerge: "Contents/MacOS/DiffMerge"
        case .araxisMerge: "Contents/Utilities/compare"
        case .p4Merge: "Contents/MacOS/p4merge"
        case .custom: ""
        }
    }

    public var cliPaths: [String] {
        if self == .fileMerge {
            return ["/usr/bin/opendiff", "/Applications/Xcode.app/" + embeddedCLI]
        }
        let app: String
        switch self {
        case .vsCode: app = "Visual Studio Code"
        case .p4Merge: app = "p4merge"
        case .beyondCompare: app = "Beyond Compare"
        case .araxisMerge: app = "Araxis Merge"
        case .kaleidoscope: app = "Kaleidoscope"
        case .diffMerge: app = "DiffMerge"
        case .cursor: app = "Cursor"
        case .fileMerge, .custom: return []
        }
        let bundled = "/Applications/" + app + ".app/" + embeddedCLI
        // Only use the bundled Araxis compare, since ImageMagick also installs a CLI of that name.
        if self == .araxisMerge { return [bundled] }
        let name = URL(fileURLWithPath: embeddedCLI).lastPathComponent.lowercased()
        return [bundled, "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
    }

    public var defaultDiffArguments: [String] {
        switch self {
        case .vsCode, .cursor: ["--wait", "--diff", "$LEFT", "$RIGHT"]
        case .fileMerge: ["$LEFT", "$RIGHT"]
        case .araxisMerge: ["-wait", "-2", "$LEFT", "$RIGHT"]
        case .kaleidoscope: ["--wait", "$LEFT", "$RIGHT"]
        default: ["$LEFT", "$RIGHT"]
        }
    }

    public var defaultMergeArguments: [String] {
        switch self {
        case .kaleidoscope: ["--merge", "--wait", "--output", "$MERGED", "--base", "$BASE", "$LEFT", "$RIGHT"]
        case .beyondCompare: ["$LEFT", "$RIGHT", "$BASE", "-mergeoutput=$MERGED"]
        case .vsCode, .cursor: ["--wait", "--merge", "$RIGHT", "$LEFT", "$BASE", "$MERGED"]
        case .fileMerge: ["$LEFT", "$RIGHT", "-ancestor", "$BASE", "-merge", "$MERGED"]
        case .diffMerge: ["--merge", "--result=$MERGED", "$LEFT", "$BASE", "$RIGHT"]
        case .araxisMerge: ["-wait", "-merge", "-3", "-a1", "$BASE", "$LEFT", "$RIGHT", "$MERGED"]
        case .p4Merge: ["$BASE", "$RIGHT", "$LEFT", "$MERGED"]
        case .custom: ["$BASE", "$LEFT", "$RIGHT", "$MERGED"]
        }
    }
}

public struct ExternalToolSelection: Codable, Equatable, Sendable {
    public var preset: ExternalToolPreset
    public var customExecutable: String
    public var customArguments: [String]

    public init(preset: ExternalToolPreset = .fileMerge, customExecutable: String = "", customArguments: [String] = [])
    {
        self.preset = preset
        self.customExecutable = customExecutable
        self.customArguments = customArguments
    }

    public func arguments(for kind: ExternalToolKind) -> [String] {
        if preset == .custom { return customArguments }
        return kind == .diff ? preset.defaultDiffArguments : preset.defaultMergeArguments
    }
}

public struct ExternalToolConfig: Codable, Equatable, Sendable {
    public var diffTool: ExternalToolSelection
    public var mergeTool: ExternalToolSelection
    private static let key = "Gita.externalTools"

    public init(diffTool: ExternalToolSelection = .init(), mergeTool: ExternalToolSelection = .init()) {
        self.diffTool = diffTool
        self.mergeTool = mergeTool
    }

    public static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key), let config = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return config
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

public enum ExternalToolDetection: Equatable, Sendable {
    case installed(executablePath: String)
    case notInstalled
}

public enum ExternalMergeOutcome: Equatable, Sendable {
    case resolved
    case unchanged
}

public enum ExternalToolLaunchState: Equatable, Sendable {
    case idle, launching
    case launched(toolName: String)
    case failed(String)
}

public enum ExternalToolError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case missingPath(String)
    case temporaryDirectory, invalidOutput
    case exited(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let name): String(localized: "\(name) is not installed.")
        case .missingPath(let key): String(localized: "No file is available for \(key).")
        case .temporaryDirectory: String(localized: "Could not prepare temporary comparison files.")
        case .invalidOutput: String(localized: "Choose a regular local file inside this worktree for the merge result.")
        case .exited(let code, let detail): String(localized: "The tool exited with status \(code). \(detail)")
        }
    }
}
