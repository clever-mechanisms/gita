import AppKit
import Foundation

/// Shared helpers for GitaUI tests: AppKit set up without running the app, and disposable Git repositories.
enum UITestSupport {
    /// Creates the shared application once so windows, views and menus can be built headlessly. Never calls `run()`.
    @MainActor static func bootstrap() {
        _ = NSApplication.shared
    }

    /// A window hosting `controller` with its view loaded and laid out.
    @MainActor static func host(
        _ controller: NSViewController, size: NSSize = NSSize(width: 1_200, height: 800)
    ) -> NSWindow {
        bootstrap()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.layoutIfNeeded()
        return window
    }

    /// Renders `view` offscreen so its `draw(_:)` runs.
    @MainActor static func render(_ view: NSView) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }
}

/// A real Git repository in a fresh temporary directory, deleted when the value is released.
final class TemporaryRepository {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "Gita Tests")
        try git("config", "user.email", "tests@example.invalid")
        try git("config", "commit.gpgsign", "false")
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `contents` to `path` (relative to the repository) and commits it.
    @discardableResult
    func commit(_ path: String, _ contents: String, message: String) throws -> String {
        try write(path, contents)
        try git("add", "--", path)
        try git("commit", "-q", "-m", message)
        return try git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ contents: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = url
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": url.path, "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFailure(arguments: arguments, status: process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }

    struct GitFailure: Error {
        let arguments: [String]
        let status: Int32
    }
}
