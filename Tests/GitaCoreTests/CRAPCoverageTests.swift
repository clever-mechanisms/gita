import Foundation
import Testing

@testable import GitaCore

@Suite("CRAP coverage · GitaCore")
struct CRAPCoreCoverageTests {
    @Test func customActionScopeSymbolsAndErrors() {
        for scope in CustomActionScope.allCases {
            #expect(!scope.symbolName.isEmpty)
            #expect(!scope.localizedTitle.isEmpty)
            #expect(!scope.supportedPlaceholders.isEmpty)
        }
        let stackErrors: [BranchStackError] = [
            .updateRefsUnsupported,
            .branchCheckedOutInOtherWorktree("/tmp/wt"),
            .emptyStack,
            .noBaseBranch,
        ]
        for error in stackErrors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func externalToolPresetsErrorsAndDetection() {
        for preset in ExternalToolPreset.allCases {
            #expect(!preset.displayName.isEmpty)
            _ = preset.bundleIdentifiers
            _ = preset.embeddedCLI
            _ = preset.cliPaths
            #expect(!preset.defaultDiffArguments.isEmpty)
            #expect(!preset.defaultMergeArguments.isEmpty)
        }
        let errors: [ExternalToolError] = [
            .unavailable("Tool"),
            .missingPath("$LEFT"),
            .temporaryDirectory,
            .invalidOutput,
            .exited(2, "boom"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }

        let cliPath = ExternalToolPreset.kaleidoscope.cliPaths[0]
        let cliDetector = ExternalToolDetector(fileExists: { $0 == cliPath }, applicationURL: { _ in nil })
        #expect(cliDetector.detect(.kaleidoscope) == .installed(executablePath: cliPath))

        let bundleURL = URL(fileURLWithPath: "/Applications/Custom.app")
        let embedded = bundleURL.appending(path: ExternalToolPreset.diffMerge.embeddedCLI).path
        let bundleDetector = ExternalToolDetector(
            fileExists: { $0 == embedded },
            applicationURL: { id in id == ExternalToolPreset.diffMerge.bundleIdentifiers.first ? bundleURL : nil }
        )
        #expect(bundleDetector.detect(.diffMerge) == .installed(executablePath: embedded))
        #expect(bundleDetector.detect(.beyondCompare) == .notInstalled)
    }

    @Test func externalToolResolutionAndMergeValidation() async throws {
        let custom = ExternalToolSelection(
            preset: .custom, customExecutable: "/usr/bin/diff", customArguments: ["$LEFT", "$RIGHT"])
        let resolved = try ExternalToolLauncher.resolveCommand(
            selection: custom, kind: .diff, paths: ["$LEFT": "/tmp/a", "$RIGHT": "/tmp/b"], detector: .notInstalled)
        #expect(resolved.executable == "/usr/bin/diff")
        #expect(resolved.arguments == ["/tmp/a", "/tmp/b"])

        let preset = ExternalToolSelection(preset: .fileMerge)
        let installed = try ExternalToolLauncher.resolveCommand(
            selection: preset, kind: .diff, paths: ["$LEFT": "/tmp/a", "$RIGHT": "/tmp/b"],
            detector: .installed(executablePath: "/usr/bin/opendiff"))
        #expect(installed.executable == "/usr/bin/opendiff")

        #expect(throws: ExternalToolError.self) {
            _ = try ExternalToolLauncher.resolveCommand(
                selection: preset, kind: .diff, paths: ["$LEFT": "/tmp/a", "$RIGHT": "/tmp/b"],
                detector: .notInstalled)
        }
        #expect(throws: ExternalToolError.self) {
            _ = try ExternalToolLauncher.resolveCommand(
                selection: custom, kind: .diff, paths: ["$LEFT": "/tmp/a"], detector: .notInstalled)
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gita-crap-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("x".utf8).write(to: outside)
        let symlink = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let launcher = ExternalToolLauncher(
            runner: StubToolRunner(),
            detector: ExternalToolDetector(fileExists: { _ in true }, applicationURL: { _ in nil }))

        let httpURL = try #require(URL(string: "https://example.com/a.txt"))
        for badURL in [httpURL, dir, symlink, outside] {
            let req = ExternalToolMergeRequest(
                fileName: "a.txt", baseContent: Data(), leftContent: Data(), rightContent: Data(),
                mergedOutputURL: badURL, worktreeRoot: dir)
            await #expect(throws: ExternalToolError.self) {
                _ = try await launcher.launchMerge(req, selection: custom)
            }
        }
    }

    @Test func explicitEquatableConformances() {
        let wtA = GitWorktree(path: "/tmp/a", branch: "main", head: "111")
        let wtB = GitWorktree(path: "/tmp/b", branch: "feat", head: "222")
        let pair1 = WorktreeCollisionPair(
            sourceWorktree: wtA, targetWorktree: wtB,
            collisions: [], mergeTreeMessages: ["m"], hasTreeConflict: true)
        let pair2 = WorktreeCollisionPair(
            sourceWorktree: wtA, targetWorktree: wtB,
            collisions: [], mergeTreeMessages: ["m"], hasTreeConflict: false)
        let pair1Copy = pair1
        #expect(pair1 == pair1Copy)
        #expect(pair1 != pair2)

        let repo = WorkspaceRepository(root: URL(fileURLWithPath: "/tmp/r"), name: "r")
        var wrc1 = WorkspaceRepoChanges(repository: repo)
        var wrc2 = WorkspaceRepoChanges(repository: repo)
        wrc2.branch = "dev"
        let wrc1Copy = wrc1
        #expect(wrc1 == wrc1Copy)
        #expect(wrc1 != wrc2)
        wrc1.branch = "dev"
        #expect(wrc1 == wrc2)

        let ep = DiffMoveEndpoint(
            filePath: "a.swift", lineIndices: 1..<2, displayStartLine: 1, displayEndLine: 1)
        let move1 = DiffMoveMatch(id: "1", source: ep, destination: ep)
        let move2 = DiffMoveMatch(id: "2", source: ep, destination: ep)
        let move1Copy = move1
        #expect(move1 == move1Copy)
        #expect(move1 != move2)

        let m1 = HistoryZoomMetrics.resolve(zoomScale: 0.5)
        let m2 = HistoryZoomMetrics.resolve(zoomScale: 1.4)
        let m1Copy = m1
        #expect(m1 == m1Copy)
        #expect(m1 != m2)

        let se1 = StructuredDiffEntry(id: "1", keyPath: "a", kind: .added, oldValue: nil, newValue: "1", section: nil)
        let se2 = StructuredDiffEntry(id: "2", keyPath: "a", kind: .removed, oldValue: "1", newValue: nil, section: "s")
        let se1Copy = se1
        #expect(se1 == se1Copy)
        #expect(se1 != se2)

        let p1 = PairwiseMergePrediction(
            oursRef: "main", theirsRef: "feat", outcome: .clean(treeID: "t"))
        let p2 = PairwiseMergePrediction(
            oursRef: "main", theirsRef: "feat", outcome: .clean(treeID: "u"))
        let p1Copy = p1
        #expect(p1 == p1Copy)
        #expect(p1 != p2)

        let cp1 = ConflictPreview(excerpt: "hi", truncated: false, totalByteCount: 2)
        let cp2 = ConflictPreview(excerpt: "bye", truncated: true, totalByteCount: 3)
        let cp1Copy = cp1
        #expect(cp1 == cp1Copy)
        #expect(cp1 != cp2)

        let cs1 = CheckoutStorageReport(
            path: URL(fileURLWithPath: "/tmp/a"), isMainWorktree: true, worktree: wtA,
            totalAllocatedBytes: 10, totalLogicalBytes: 10, fileCount: 1, heavyFolders: [], lastModifiedDate: nil)
        let cs2 = CheckoutStorageReport(
            path: URL(fileURLWithPath: "/tmp/b"), isMainWorktree: false, worktree: wtB,
            totalAllocatedBytes: 20, totalLogicalBytes: 20, fileCount: 2, heavyFolders: [], lastModifiedDate: nil)
        let cs1Copy = cs1
        #expect(cs1 == cs1Copy)
        #expect(cs1 != cs2)
    }
}

private struct StubToolRunner: CommandRunning {
    func run(
        executable _: String, arguments _: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
    ) async throws -> CommandResult {
        CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}
