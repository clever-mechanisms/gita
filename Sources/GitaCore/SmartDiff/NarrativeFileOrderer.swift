import Foundation

public enum NarrativeLayer: String, CaseIterable, Sendable, Equatable, Hashable, Comparable {
    case schemasAndModels, coreLogic, uiAndViews, tests, configAndBuild, generatedAndLockfiles

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs) ?? 0 < allCases.firstIndex(of: rhs) ?? 0
    }

    public var displayTitle: String {
        switch self {
        case .schemasAndModels: String(localized: "Schemas and models")
        case .coreLogic: String(localized: "Core logic")
        case .uiAndViews: String(localized: "UI and views")
        case .tests: String(localized: "Tests")
        case .configAndBuild: String(localized: "Configuration and build")
        case .generatedAndLockfiles: String(localized: "Generated files and lockfiles")
        }
    }

    public var symbolName: String {
        switch self {
        case .schemasAndModels: "square.3.layers.3d"
        case .coreLogic: "curlybraces"
        case .uiAndViews: "macwindow"
        case .tests: "checkmark.diamond"
        case .configAndBuild: "gearshape"
        case .generatedAndLockfiles: "lock.doc"
        }
    }

    public var collapsedByDefault: Bool { self == .generatedAndLockfiles }
}

public enum FileOrderMode: String, CaseIterable, Sendable, Equatable {
    case narrative, pathTree, alphabetical
}

public struct NarrativeFileEntry: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let additions: Int
    public let deletions: Int
    public let fileChange: FileChange?

    public init(
        path: String, originalPath: String? = nil, additions: Int = 0, deletions: Int = 0,
        fileChange: FileChange? = nil
    ) {
        self.path = path
        self.originalPath = originalPath
        self.additions = max(0, additions)
        self.deletions = max(0, deletions)
        self.fileChange = fileChange
    }

    public init(_ fileChange: FileChange, additions: Int = 0, deletions: Int = 0) {
        self.init(
            path: fileChange.path, originalPath: fileChange.originalPath,
            additions: additions, deletions: deletions, fileChange: fileChange)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path
            && lhs.originalPath == rhs.originalPath
            && lhs.additions == rhs.additions
            && lhs.deletions == rhs.deletions
            && lhs.fileChange == rhs.fileChange
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(originalPath)
        hasher.combine(additions)
        hasher.combine(deletions)
        hasher.combine(fileChange)
    }
}

public struct NarrativeFileGroup: Identifiable, Sendable, Equatable {
    public var id: String { layer.rawValue }
    public let layer: NarrativeLayer
    public let entries: [NarrativeFileEntry]
    public let mode: FileOrderMode
    public var displayTitle: String { mode == .narrative ? layer.displayTitle : String(localized: "Files") }
    public let collapsedByDefault: Bool
    public var totalAdditions: Int { entries.reduce(0) { $0 + min(Int.max - $0, $1.additions) } }
    public var totalDeletions: Int { entries.reduce(0) { $0 + min(Int.max - $0, $1.deletions) } }
}

public enum NarrativeFileOrderer {
    private struct Path {
        let raw: String
        let name: String
        let ext: String
        let folders: Set<String>
        let directory: String

        init(_ value: String) {
            raw = value
            let parts = value.lowercased().split(separator: "/").map(String.init)
            name = parts.last ?? ""
            ext = name.split(separator: ".", omittingEmptySubsequences: false).dropFirst().last.map(String.init) ?? ""
            folders = Set(parts.dropLast())
            directory = String(value[..<(value.lastIndex(of: "/") ?? value.startIndex)])
        }

        func within(_ names: Set<String>) -> Bool { !folders.isDisjoint(with: names) }
        func ends(_ suffixes: [String]) -> Bool { suffixes.contains { name.hasSuffix($0) } }

        var generated: Bool {
            within(["generated", "__generated__", "dist", "node_modules", "deriveddata", "vendor"])
                || name.contains(".generated.") || name.contains(".min.") || name.hasPrefix("generated.")
                || ends([
                    ".lock", "-lock.json", "package.resolved", "go.sum", ".pb.go", ".pb.swift", "_pb2.py",
                    ".g.dart", ".g.cs", "pnpm-lock.yaml", "bun.lockb", ".designer.cs", ".js.map", ".css.map",
                ])
        }

        var test: Bool {
            folders.contains { $0.hasSuffix("tests") || ["test", "__tests__", "spec", "specs"].contains($0) }
                || name.hasPrefix("test_") || name.contains(".test.") || name.contains(".spec.")
                || ends(["_test.go", "_test.py", "_test.rs", "tests.swift", "test.swift", "test.java"])
        }

        var config: Bool {
            within([".github", ".circleci", "config", "configs", "scripts", ".buildkite", "cmake"])
                || name.hasPrefix("dockerfile") || name.hasPrefix("tsconfig") || name.contains(".config.")
                || [
                    "package.swift", "package.json", "makefile", "cargo.toml", "go.mod", "pyproject.toml",
                    ".gitlab-ci.yml", "cmakelists.txt", "requirements.txt", "gemfile", "build.gradle",
                    "project.pbxproj", "podfile", ".gitignore", ".gitattributes", ".editorconfig", ".swiftlint.yml",
                    "vercel.json", "deno.json", "setup.cfg", "tox.ini", "jenkinsfile",
                ].contains(name)
                || ends([".xcconfig", ".xcscheme", ".gradle.kts"])
        }

        var model: Bool {
            within(["models", "model", "schemas", "schema", "migrations", "entities", "types", "proto"])
                || ["sql", "graphql", "gql", "proto", "graphqls", "xsd"].contains(ext)
                || ends(["model.swift", "models.py", ".model.ts", ".schema.ts", ".d.ts"])
                || name.hasPrefix("openapi.") || name.hasPrefix("swagger.")
        }

        var view: Bool {
            within(["ui", "views", "components", "screens", "styles", "templates", "swiftui", "appkit", "assets"])
                || ["svg", "html", "tsx", "jsx", "xib", "storyboard", "css", "scss", "sass", "less", "vue", "svelte"]
                    .contains(ext)
                || ends(["view.swift", "viewcontroller.swift", "windowcontroller.swift"])
        }

        var reviewPriority: Int {
            if ["h", "hpp", "hxx", "pyi"].contains(ext) || name.contains("protocol") || name.contains("interface")
                || within(["interfaces", "protocols"])
            {
                return 0
            }
            return ends(["model.swift", ".model.ts", ".d.ts", "models.py"]) ? 1 : 2
        }
    }

    public static func classify(path: String) -> NarrativeLayer {
        let path = Path(path)
        if path.generated { return .generatedAndLockfiles }
        if path.test { return .tests }
        if path.model { return .schemasAndModels }
        if path.config { return .configAndBuild }
        return path.view ? .uiAndViews : .coreLogic
    }

    public static func group(_ files: [FileChange], mode: FileOrderMode = .narrative) -> [NarrativeFileGroup] {
        group(files.map { NarrativeFileEntry($0) }, mode: mode)
    }

    public static func group(_ entries: [NarrativeFileEntry], mode: FileOrderMode = .narrative) -> [NarrativeFileGroup]
    {
        guard !entries.isEmpty else { return [] }
        let groups = Dictionary(grouping: entries) { mode == .narrative ? classify(path: $0.path) : .coreLogic }
        return groups.keys.sorted().map { layer in
            let keyed = groups[layer, default: []].map { (entry: $0, path: Path($0.path)) }
            let sorted = keyed.sorted { lhs, rhs in
                if mode == .alphabetical, lhs.path.name != rhs.path.name { return lhs.path.name < rhs.path.name }
                if mode != .alphabetical, lhs.path.directory != rhs.path.directory {
                    return lhs.path.directory < rhs.path.directory
                }
                if mode == .narrative, lhs.path.reviewPriority != rhs.path.reviewPriority {
                    return lhs.path.reviewPriority < rhs.path.reviewPriority
                }
                return lhs.path.raw < rhs.path.raw
            }
            return NarrativeFileGroup(
                layer: layer, entries: sorted.map(\.entry), mode: mode,
                collapsedByDefault: layer.collapsedByDefault)
        }
    }
}
