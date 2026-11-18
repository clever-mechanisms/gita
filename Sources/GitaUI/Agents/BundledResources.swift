import Foundation
import os

/// Where Gita finds the files it ships: `Contents/Resources` of the app. Under `swift test` `Bundle.main` is the
/// test runner, so tests point `root` at the source tree's `Resources` folder.
enum BundledResources {
    private static let storage = OSAllocatedUnfairLock<URL?>(initialState: Bundle.main.resourceURL)

    static var root: URL? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// A file below `root`.
    static func url(_ relativePath: String) -> URL? { root?.appendingPathComponent(relativePath) }
}
