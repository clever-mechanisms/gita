import Foundation
import Testing

@testable import GitaCore

@Suite struct ActionsToolsExternalToolsTests {
    private let paths = ["$LEFT": "a $RIGHT", "$RIGHT": "$(id) b", "$BASE": "base", "$MERGED": "merge result"]

    @Test func allPresetCommands() throws {
        for preset in ExternalToolPreset.allCases {
            for kind in ExternalToolKind.allCases {
                let templates = kind == .diff ? preset.defaultDiffArguments : preset.defaultMergeArguments
                let selection = ExternalToolSelection(
                    preset: preset, customExecutable: "custom", customArguments: templates)
                let command = try ExternalToolLauncher.resolveCommand(
                    selection: selection, kind: kind, paths: paths,
                    detector: .installed(executablePath: "/cli"))
                #expect(command.executable == (preset == .custom ? "custom" : "/cli"))
                #expect(command.arguments.contains("a $RIGHT"))
                #expect(command.arguments.contains("$(id) b"))
                #expect(command.arguments.count == templates.count)
                if kind == .merge {
                    #expect(command.arguments.contains("base"))
                    #expect(command.arguments.contains(where: { $0.hasSuffix("merge result") }))
                }
            }
        }
    }

    @Test func resolveUnavailableAndMissingInputs() {
        let selection = ExternalToolSelection(preset: .vsCode)
        #expect(throws: ExternalToolError.unavailable(selection.preset.displayName)) {
            try ExternalToolLauncher.resolveCommand(
                selection: selection, kind: .diff, paths: paths, detector: .notInstalled)
        }
        for inputs in [["$LEFT": "left"], ["$LEFT": "left", "$RIGHT": ""]] {
            #expect(throws: ExternalToolError.missingPath("$RIGHT")) {
                try ExternalToolLauncher.resolveCommand(
                    selection: selection, kind: .diff, paths: inputs, detector: .installed(executablePath: "/cli"))
            }
        }
    }

    @Test func customResolutionAndShellGuards() throws {
        var selection = ExternalToolSelection(
            preset: .custom, customExecutable: "diff tool",
            customArguments: ["--left=$LEFT", "$RIGHT", "$LEFT_EXTRA", ""])
        let command = try ExternalToolLauncher.resolveCommand(
            selection: selection, kind: .diff, paths: paths,
            detector: .notInstalled)
        #expect(command.arguments == ["--left=a $RIGHT", "$(id) b", "$LEFT_EXTRA", ""])
        selection.customExecutable = "/bin/sh"
        selection.customArguments = ["-lc", "$LEFT"]
        #expect(throws: CustomActionError.shellCommand) {
            try ExternalToolLauncher.resolveCommand(
                selection: selection, kind: .diff, paths: paths, detector: .notInstalled)
        }
        selection.customExecutable = "diff"
        selection.customArguments = ["$LEFT"]
        #expect(throws: CustomActionError.invalidArgument) {
            try ExternalToolLauncher.resolveCommand(
                selection: selection, kind: .diff, paths: ["$LEFT": "a\0b"],
                detector: .notInstalled)
        }
    }

    @Test func detectsStandaloneAndRelocatedCLI() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Editors")
        let embedded = root.appending(path: "Contents/Resources/app/bin/code").path
        let detector = ExternalToolDetector(
            fileExists: { $0 == embedded || $0 == "/usr/local/bin/bcomp" },
            applicationURL: { $0 == "com.microsoft.VSCode" ? root : nil })
        let all = await detector.detectAll()
        #expect(all[.vsCode] == .installed(executablePath: embedded))
        #expect(all[.beyondCompare] == .installed(executablePath: "/usr/local/bin/bcomp"))
        #expect(all[.fileMerge] == .notInstalled)
        #expect(all.count == ExternalToolPreset.allCases.count)
    }

    @Test func detectionPrefersKnownPathsInOrder() {
        let detector = ExternalToolDetector(
            fileExists: { _ in true },
            applicationURL: { _ in
                Issue.record("Bundle lookup should only run after known paths are exhausted")
                return nil
            })
        #expect(detector.detect(.fileMerge) == .installed(executablePath: "/usr/bin/opendiff"))
        #expect(detector.detect(.custom) == .notInstalled)
    }

    @Test func detectionSkipsMissingBundlesAndEmbeddedExecutables() {
        let apps = URL(filePath: "/Editors")
        let installed = apps.appending(path: "Kaleidoscope 4.app/Contents/MacOS/ksdiff").path
        let bundles = [
            "app.kaleidoscope.v5": apps.appending(path: "Incomplete.app"),
            "app.kaleidoscope.v4": apps.appending(path: "Kaleidoscope 4.app"),
            "app.kaleidoscope.v3": apps.appending(path: "Kaleidoscope 3.app"),
        ]
        let detector = ExternalToolDetector(
            fileExists: { $0 == installed || $0.hasSuffix("Kaleidoscope 3.app/Contents/MacOS/ksdiff") },
            applicationURL: { bundles[$0] })
        #expect(detector.detect(.kaleidoscope) == .installed(executablePath: installed))
    }

    @Test func diffAcceptsExitCodeOneAndCleansUp() async throws {
        let mock = SnapshotCommandRunner(exitCode: 1)
        let launcher = ExternalToolLauncher(runner: mock)
        let request = ExternalToolDiffRequest(
            fileName: "../../outside/name.swift", leftContent: Data([0, 2]),
            rightContent: Data([3, 4]), leftLabel: "../before", rightLabel: "../after")
        let handle = try launcher.prepareDiff(request)
        defer { try? handle.cleanup() }
        for (key, path) in handle.paths {
            #expect(path.hasPrefix(handle.directory.path + "/") && path.hasSuffix("/name.swift"))
            #expect(!path.contains("/../"))
            #expect(
                try Data(contentsOf: URL(filePath: path))
                    == (key == "$LEFT" ? request.leftContent : request.rightContent))
        }
        let selection = ExternalToolSelection(
            preset: .custom, customExecutable: "diff", customArguments: ["$LEFT", "$RIGHT"])
        try await launcher.launchDiff(request, selection: selection)
        let folder = try #require(await mock.directory)
        #expect(await mock.contents == [request.leftContent, request.rightContent])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let failing = ExternalToolLauncher(runner: SnapshotCommandRunner(exitCode: 2))
        await #expect(throws: ExternalToolError.self) { try await failing.launchDiff(request, selection: selection) }
    }

    @Test func mergeStagingOutcome() async throws {
        let worktree = FileManager.default.temporaryDirectory.appending(path: "wt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        let output = worktree.appending(path: "name.txt")
        let initial = Data("<<<<<<< conflict\n".utf8)
        try initial.write(to: output)
        let selection = ExternalToolSelection(
            preset: .custom, customExecutable: "merge",
            customArguments: ["$BASE", "$LEFT", "$RIGHT", "$MERGED"])
        let request = ExternalToolMergeRequest(
            fileName: "name.txt", baseContent: Data([1]), leftContent: Data([2]),
            rightContent: Data([3]), mergedOutputURL: output, worktreeRoot: worktree)

        // Closing without saving reports .unchanged and leaves destination untouched.
        let unchangedLauncher = ExternalToolLauncher(runner: SnapshotCommandRunner(writeMerged: false))
        let noChange = try await unchangedLauncher.launchMerge(request, selection: selection)
        #expect(noChange == .unchanged)
        #expect(try Data(contentsOf: output) == initial)

        // Editing the staged temp file writes back atomically and reports .resolved.
        let mock = SnapshotCommandRunner(writeMerged: true)
        let resolvedLauncher = ExternalToolLauncher(runner: mock)
        let resolved = try await resolvedLauncher.launchMerge(request, selection: selection)
        #expect(resolved == .resolved)
        #expect(await mock.contents == [request.baseContent, request.leftContent, request.rightContent])
        #expect(try Data(contentsOf: output) == Data("merged".utf8))
        let folder = try #require(await mock.directory)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func mergeDestinationMustBeALocalRegularFileInTheWorktree() async throws {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let tree = parent.appending(path: "repo")
        let sibling = parent.appending(path: "repo-backup")
        try manager.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: parent) }
        try manager.createDirectory(at: sibling, withIntermediateDirectories: false)
        let output = tree.appending(path: "result.txt")
        let outside = sibling.appending(path: "result.txt")
        try Data("result".utf8).write(to: output)
        try Data("outside".utf8).write(to: outside)
        let fileLink = tree.appending(path: "link.txt")
        let directoryLink = tree.appending(path: "elsewhere")
        try manager.createSymbolicLink(at: fileLink, withDestinationURL: output)
        try manager.createSymbolicLink(at: directoryLink, withDestinationURL: sibling)

        var address = try #require(URLComponents(url: output, resolvingAgainstBaseURL: false))
        address.host = "localhost"
        let local = try #require(address.url)
        address.scheme = "https"
        let web = try #require(address.url)
        address.scheme = "file"
        address.host = "other.example"
        let remote = try #require(address.url)
        let selection = ExternalToolSelection(preset: .custom, customExecutable: "merge", customArguments: ["$MERGED"])
        let runner = SnapshotCommandRunner(writeMerged: false)
        let launcher = ExternalToolLauncher(runner: runner)
        func merge(_ target: URL, root: URL) async throws -> ExternalMergeOutcome {
            let request = ExternalToolMergeRequest(
                fileName: "result.txt", baseContent: Data(), leftContent: Data(), rightContent: Data(),
                mergedOutputURL: target, worktreeRoot: root)
            return try await launcher.launchMerge(request, selection: selection)
        }
        for target in [
            tree, tree.appending(path: "missing"), fileLink, outside,
            directoryLink.appending(path: "result.txt"), web, remote,
        ] {
            await #expect(throws: ExternalToolError.invalidOutput) { try await merge(target, root: tree) }
        }
        #expect(await runner.directory == nil)
        #expect(try await merge(local, root: URL(filePath: "/")) == .unchanged)
    }

    @Test func persistsIndependentSelections() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = ExternalToolConfig(
            diffTool: .init(preset: .vsCode),
            mergeTool: .init(preset: .custom, customExecutable: "cli", customArguments: ["$BASE"]))
        config.save(to: defaults)
        #expect(ExternalToolConfig.load(from: defaults) == config)
    }
}

private actor SnapshotCommandRunner: CommandRunning {
    let exitCode: Int32
    let writeMerged: Bool
    var directory: URL?
    var contents: [Data] = []

    init(exitCode: Int32 = 0, writeMerged: Bool = true) {
        self.exitCode = exitCode
        self.writeMerged = writeMerged
    }

    func run(
        executable: String, arguments: [String], directory: URL?, timeout _: TimeInterval,
        outputLimit _: Int
    ) async throws -> CommandResult {
        self.directory = directory
        let inputs = executable == "merge" ? Array(arguments.dropLast()) : arguments
        contents = try inputs.map { try Data(contentsOf: URL(filePath: $0)) }
        if executable == "merge", writeMerged, let output = arguments.last {
            try Data("merged".utf8).write(to: URL(filePath: output))
        }
        return CommandResult(stdout: Data(), stderr: Data(), exitCode: exitCode)
    }
}
