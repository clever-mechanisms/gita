import Darwin
import Foundation

public struct ExternalToolDiffRequest: Equatable, Sendable {
    public var fileName: String
    public var leftContent: Data
    public var rightContent: Data
    public var leftLabel: String
    public var rightLabel: String

    public init(fileName: String, leftContent: Data, rightContent: Data, leftLabel: String, rightLabel: String) {
        self.fileName = fileName
        self.leftContent = leftContent
        self.rightContent = rightContent
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
    }
}

public struct ExternalToolMergeRequest: Equatable, Sendable {
    public var fileName: String
    public var baseContent: Data
    public var leftContent: Data
    public var rightContent: Data
    public var mergedOutputURL: URL
    public var worktreeRoot: URL

    public init(
        fileName: String, baseContent: Data, leftContent: Data, rightContent: Data, mergedOutputURL: URL,
        worktreeRoot: URL
    ) {
        self.fileName = fileName
        self.baseContent = baseContent
        self.leftContent = leftContent
        self.rightContent = rightContent
        self.mergedOutputURL = mergedOutputURL
        self.worktreeRoot = worktreeRoot
    }
}

public struct ExternalToolSnapshots: Sendable {
    public let directory: URL
    public let paths: [String: String]

    public func cleanup() throws {
        do { try FileManager.default.removeItem(at: directory) } catch let error as CocoaError
            where error.code == .fileNoSuchFile
        { return }
    }
}

public struct ExternalToolLauncher: Sendable {
    private let runner: any CommandRunning
    private let detector: ExternalToolDetector
    public init(runner: any CommandRunning = CommandRunner(), detector: ExternalToolDetector = ExternalToolDetector()) {
        self.runner = runner
        self.detector = detector
    }

    /// Resolution uses the caller's detection result so previews and tests need no filesystem access.
    public static func resolveCommand(
        selection: ExternalToolSelection, kind: ExternalToolKind,
        paths: [String: String], detector: ExternalToolDetection
    ) throws -> (executable: String, arguments: [String]) {
        let executable: String
        if selection.preset == .custom {
            executable = selection.customExecutable
        } else if case .installed(let path) = detector {
            executable = path
        } else {
            throw ExternalToolError.unavailable(selection.preset.displayName)
        }
        let templateArguments = selection.arguments(for: kind)
        try CommandTemplate.validateTemplate(
            executable: executable, arguments: templateArguments,
            knownPlaceholders: CommandTemplate.toolPlaceholders)
        let arguments = try templateArguments.map { token in
            try CommandTemplate.expand(token) { key in
                guard CommandTemplate.toolPlaceholders.contains(key) else { return nil }
                guard let path = paths[key], !path.isEmpty else { throw ExternalToolError.missingPath(key) }
                return path
            }
        }
        try CommandTemplate.validate(executable: executable, arguments: arguments)
        return (executable, arguments)
    }

    public func prepareDiff(_ request: ExternalToolDiffRequest) throws -> ExternalToolSnapshots {
        try snapshots(
            name: request.fileName,
            inputs: [
                ("$LEFT", request.leftLabel, request.leftContent), ("$RIGHT", request.rightLabel, request.rightContent),
            ])
    }

    public func launchDiff(_ request: ExternalToolDiffRequest, selection: ExternalToolSelection) async throws {
        let files = try prepareDiff(request)
        defer { try? files.cleanup() }
        try await launch(selection, kind: .diff, files: files)
    }

    @discardableResult
    public func launchMerge(
        _ request: ExternalToolMergeRequest, selection: ExternalToolSelection
    ) async throws -> ExternalMergeOutcome {
        try Self.validateMergeDestination(request.mergedOutputURL, worktreeRoot: request.worktreeRoot)
        let initial = try Data(contentsOf: request.mergedOutputURL)
        let files = try snapshots(
            name: request.fileName,
            inputs: [
                ("$LEFT", "left", request.leftContent), ("$RIGHT", "right", request.rightContent),
                ("$BASE", "base", request.baseContent), ("$MERGED", "merged", initial),
            ])
        defer { try? files.cleanup() }
        try await launch(selection, kind: .merge, files: files)
        guard let stagedPath = files.paths["$MERGED"] else { throw ExternalToolError.temporaryDirectory }
        let updated = try Data(contentsOf: URL(fileURLWithPath: stagedPath))
        guard updated != initial else { return .unchanged }
        try Self.validateMergeDestination(request.mergedOutputURL, worktreeRoot: request.worktreeRoot)
        let current = try Data(contentsOf: request.mergedOutputURL)
        guard current == initial else { throw ExternalToolError.invalidOutput }
        try updated.write(to: request.mergedOutputURL, options: .atomic)
        return .resolved
    }

    public func testLaunch(selection: ExternalToolSelection, kind: ExternalToolKind) async throws {
        let left = Data("first\nsecond\n".utf8)
        let right = Data("first\nthird\n".utf8)
        if kind == .diff {
            try await launchDiff(
                ExternalToolDiffRequest(
                    fileName: "sample.txt", leftContent: left, rightContent: right,
                    leftLabel: "left", rightLabel: "right"), selection: selection)
        } else {
            let files = try snapshots(
                name: "sample.txt",
                inputs: [
                    ("$LEFT", "left", left), ("$RIGHT", "right", right),
                    ("$BASE", "base", Data("first\n".utf8)), ("$MERGED", "result", left),
                ])
            defer { try? files.cleanup() }
            try await launch(selection, kind: kind, files: files)
        }
    }

    private func launch(
        _ selection: ExternalToolSelection, kind: ExternalToolKind,
        files: ExternalToolSnapshots
    ) async throws {
        let command = try Self.resolveCommand(
            selection: selection, kind: kind, paths: files.paths,
            detector: detector.detect(selection.preset))
        let result = try await runner.run(
            CommandRequest(
                executable: command.executable, arguments: command.arguments,
                directory: files.directory, timeout: 24 * 60 * 60))
        let accepted: Set<Int32> = kind == .diff ? [0, 1] : [0]
        guard accepted.contains(result.exitCode) else {
            throw ExternalToolError.exited(
                result.exitCode, String(decoding: result.stderr.prefix(4_096), as: UTF8.self))
        }
    }

    private static func validateMergeDestination(_ url: URL, worktreeRoot: URL) throws {
        guard url.isFileURL, url.host?.isEmpty != false || url.host == "localhost" else {
            throw ExternalToolError.invalidOutput
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ExternalToolError.invalidOutput
        }
        let resolvedRoot = worktreeRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        let resolvedFile = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedFile.hasPrefix(prefix) else { throw ExternalToolError.invalidOutput }
    }

    private func snapshots(name: String, inputs: [(String, String, Data)]) throws -> ExternalToolSnapshots {
        let directory = try PrivateTemporaryDirectory.make(
            prefix: "gita-exttool", failure: ExternalToolError.temporaryDirectory)
        do {
            var paths: [String: String] = [:]
            let basename = Self.component(URL(fileURLWithPath: name).lastPathComponent)
            for (key, label, data) in inputs {
                let side = key.dropFirst().lowercased() + "-" + Self.component(label)
                let folder = directory.appending(path: side, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let file = folder.appending(path: basename)
                try data.write(to: file, options: .withoutOverwriting)
                paths[key] = file.path
            }
            return ExternalToolSnapshots(directory: directory, paths: paths)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func component(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        let clean = text.components(separatedBy: allowed.inverted).joined(separator: "_")
        return ["", ".", ".."].contains(clean) ? "snapshot" : clean
    }
}
