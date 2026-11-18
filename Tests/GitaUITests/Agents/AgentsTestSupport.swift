import AppKit
import Foundation

@testable import GitaCore

/// Events a fake hands to a test as they happen (a call, a published list), awaited in order without sleeping.
final class AgentsEvents<Element: Sendable>: Sendable {
    private let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(of: Element.self) }

    func yield(_ element: Element) { continuation.yield(element) }

    /// The next event; the suites' time limit fails a test that waits for one that never comes.
    func next() async -> Element? {
        for await element in stream { return element }
        return nil
    }

    /// Events until one matches.
    func next(where matches: @Sendable (Element) -> Bool) async -> Element? {
        for await element in stream where matches(element) { return element }
        return nil
    }
}

/// Posts of one notification from one sender, as events.
@MainActor
final class AgentsNotifications {
    let events = AgentsEvents<Void>()
    private var token: NSObjectProtocol?

    init(_ name: Notification.Name, object: AnyObject?) {
        let events = events
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { _ in
            events.yield(())
        }
    }

    isolated deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    func next() async { _ = await events.next() }
}

/// A private defaults domain and a temporary folder for one test, both removed afterwards.
final class AgentsSandbox {
    let defaults: UserDefaults
    let folder: URL
    private let suite: String

    init(_ area: String) throws {
        suite = "GitaUITests.\(area).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.featureUnsupported) }
        self.defaults = defaults
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaUITests-\(area)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    /// A folder inside the sandbox, created.
    @discardableResult
    func directory(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An executable file inside the sandbox.
    @discardableResult
    func executable(_ path: String) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

/// A command runner that records every call and answers from a closure; nothing is ever executed.
actor AgentsRecordingRunner: CommandRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    /// Every call as it happens.
    nonisolated let events = AgentsEvents<Call>()
    private let response: @Sendable (Call) -> CommandResult

    init(response: @escaping @Sendable (Call) -> CommandResult = { _ in AgentsRecordingRunner.result("") }) {
        self.response = response
    }

    func run(
        executable: String, arguments: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
    ) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments)
        calls.append(call)
        events.yield(call)
        return response(call)
    }

    static func result(_ stdout: String, exitCode: Int32 = 0) -> CommandResult {
        CommandResult(stdout: Data(stdout.utf8), stderr: Data(), exitCode: exitCode)
    }
}

/// A small PNG, for code that decodes pictures.
enum AgentsImages {
    static func png(side: Int = 4) -> Data {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return Data() }
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    /// A bitmap context to draw marks into.
    static func context(side: Int = 32) -> CGContext? {
        CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
