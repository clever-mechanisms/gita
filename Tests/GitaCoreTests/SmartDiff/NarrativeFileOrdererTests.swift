import GitaCore
import Testing

struct NarrativeFileOrdererTests {
    @Test func classification() {
        let samples: [NarrativeLayer: [String]] = [
            .schemasAndModels: ["db/migrations/001.sql", "openapi.yaml", "a.proto", "a.graphql", "Models/Foo.swift"],
            .coreLogic: ["engine/main.go", "src/lib.rs", "foo.py", "index.ts", "main.js", "Engine.swift"],
            .uiAndViews: ["a.xib", "a.storyboard", "a.scss", "Card.tsx", "CardView.swift", "views/Foo.m"],
            .tests: ["GitaCoreTests/Models/Row.swift", "main_test.go", "test_utils.py", "Card.spec.tsx"],
            .configAndBuild: [
                ".github/workflows/build.yml", "Package.swift", "Cargo.toml", "vite.config.js", "go.mod",
            ],
            .generatedAndLockfiles: ["yarn.lock", "Package.resolved", "a.min.css", "a.pb.go", "generated/foo.py"],
        ]
        for (layer, paths) in samples {
            for path in paths { #expect(NarrativeFileOrderer.classify(path: path) == layer) }
        }
    }

    @Test func reviewOrderAndStats() {
        let paths = ["Package.resolved", "Package.swift", "a.test.ts", "Card.tsx", "logic.go", "a.proto"]
        let entries = paths.map { NarrativeFileEntry(path: $0, additions: 4, deletions: 2) }
        let groups = NarrativeFileOrderer.group(entries)
        #expect(groups.map(\.layer) == NarrativeLayer.allCases)
        #expect(groups.filter(\.collapsedByDefault).map(\.layer) == [.generatedAndLockfiles])
        #expect(groups.allSatisfy { $0.totalAdditions == 4 && $0.totalDeletions == 2 })
    }

    @Test func siblingsAndFlatModes() {
        let paths = ["z/A.swift", "a/B.mm", "a/Z.h", "a/CProtocol.swift"]
        let files = paths.map { FileChange(path: $0, originalPath: "old", indexStatus: "R", worktreeStatus: " ") }
        func sorted(_ mode: FileOrderMode) -> [String] {
            NarrativeFileOrderer.group(files, mode: mode).flatMap(\.entries).map(\.path)
        }
        #expect(sorted(.narrative) == ["a/CProtocol.swift", "a/Z.h", "a/B.mm", "z/A.swift"])
        #expect(sorted(.pathTree) == ["a/B.mm", "a/CProtocol.swift", "a/Z.h", "z/A.swift"])
        #expect(sorted(.alphabetical) == ["z/A.swift", "a/B.mm", "a/CProtocol.swift", "a/Z.h"])
        #expect(NarrativeFileOrderer.group(files).first?.entries.first?.originalPath == "old")
    }
}
