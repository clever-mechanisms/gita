import Foundation

public enum HeavyFolderCatalog {
    public static let defaultLargeFolderThreshold: UInt64 = 50 * 1_024 * 1_024
    private static let categories: [String: HeavyFolderCategory] = [
        "node_modules": .javascript, ".pnpm-store": .javascript, ".next": .javascript, ".nuxt": .javascript,
        ".turbo": .javascript, ".vite": .javascript, ".parcel-cache": .javascript, ".svelte-kit": .javascript,
        ".angular": .javascript, ".build": .swift, "DerivedData": .swift, "Pods": .swift, "Carthage": .swift,
        "target": .rust, ".gradle": .jvm, ".venv": .python, "venv": .python, "__pycache__": .python,
        ".mypy_cache": .python, ".pytest_cache": .python, ".ruff_cache": .python, ".terraform": .infrastructure,
        "dist": .buildOutput, "out": .buildOutput, "coverage": .buildOutput, ".cache": .cache, "build": .buildOutput,
        ".dart_tool": .buildOutput,
    ]

    public static func category(forFolderName name: String) -> HeavyFolderCategory? { categories[name] }
    public static func isKnownHeavyFolder(_ name: String) -> Bool { categories[name] != nil }
}
