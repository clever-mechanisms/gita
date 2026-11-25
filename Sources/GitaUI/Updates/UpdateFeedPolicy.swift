import Foundation
import os

/// Policy for Sparkle 2's ungated update feed (`https://getgita.app/appcast.xml`) and official-build checks.
/// Free/MIT updates carry no license headers and never touch the Keychain or Security framework.
enum UpdateFeedPolicy {
    /// Per-process cache for official-build lookups, keyed by standardized `.app` path.
    final class OfficialBuildCache: Sendable {
        private let entries = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

        func resolve(bundleURL: URL, lookup: (URL) -> String?) -> Bool {
            guard bundleURL.pathExtension == "app" else { return false }
            let key = bundleURL.standardizedFileURL.path
            if let cached = entries.withLock({ $0[key] }) { return cached }
            let result = lookup(bundleURL) == UpdateFeedPolicy.teamIdentifier
            entries.withLock { $0[key] = result }
            return result
        }
    }

    static let productionFeedURLString = "https://getgita.app/appcast.xml"
    static let teamIdentifier = "PCZ6F8Q9DZ"
    static let feedOverrideKey = "UpdateFeedURL"
    static let codesignTimeout: TimeInterval = 2
    static let defaultOfficialBuildCache = OfficialBuildCache()

    #if DEBUG
        static let defaultAllowsAnyFeedOverrideHost = true
    #else
        static let defaultAllowsAnyFeedOverrideHost = false
    #endif

    /// True only for strict loopback hosts (`localhost`, `127.0.0.1`, `::1`, `[::1]`).
    static func isLoopbackHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1" || lowered == "[::1]"
    }

    /// Validates an `UpdateFeedURL` override from defaults. Release builds (`allowAnyHost == false`) permit only
    /// strict loopback `http`/`https` URLs without userinfo.
    static func validatedFeedOverride(
        _ raw: String?, allowAnyHost: Bool = defaultAllowsAnyFeedOverrideHost
    ) -> URL? {
        guard let components = parsedHTTPComponents(from: raw),
            hasNoCredentials(components),
            let host = components.host?.lowercased(), !host.isEmpty,
            let url = components.url
        else { return nil }
        guard allowAnyHost || isLoopbackHost(host) else { return nil }
        return url
    }

    /// Parses `TeamIdentifier=<id>` from `codesign -dv` output; ignores `"not set"` and empty values.
    static func parseTeamIdentifier(from output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(line.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.lowercased() != "not set" else { return nil }
            return value
        }
        return nil
    }

    /// True only for a `.app` bundle whose `codesign -dv` metadata claims Clever Mechanisms' Developer ID Team
    /// Identifier. Cached per process for the default lookup so repeated checks never re-spawn `codesign`.
    /// Note: `codesign -dv` inspects the bundle's claimed `TeamIdentifier` (without full signature validation or
    /// linking `Security`) solely to decide whether to enable Sparkle; Sparkle itself enforces EdDSA
    /// (`SUPublicEDKey`) and Developer ID code-signature verification on every update.
    static func isOfficialBuild(
        bundleURL: URL = Bundle.main.bundleURL,
        teamIdentifierLookup: ((URL) -> String?)? = nil
    ) -> Bool {
        if let teamIdentifierLookup {
            guard bundleURL.pathExtension == "app" else { return false }
            return teamIdentifierLookup(bundleURL) == teamIdentifier
        }
        return defaultOfficialBuildCache.resolve(bundleURL: bundleURL) { readTeamIdentifier(of: $0) }
    }

    /// Runs `isOfficialBuild(bundleURL:)` off the main actor so launching never blocks the UI thread on `codesign`.
    static func isOfficialBuildAsync(
        bundleURL: URL = Bundle.main.bundleURL,
        teamIdentifierLookup: (@Sendable (URL) -> String?)? = nil
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            isOfficialBuild(bundleURL: bundleURL, teamIdentifierLookup: teamIdentifierLookup)
        }.value
    }

    /// Inspects the bundle's claimed `TeamIdentifier` via `/usr/bin/codesign -dv` without linking `Security`,
    /// bounded by `timeout` (terminating the subprocess if wedged).
    static func readTeamIdentifier(of bundleURL: URL, timeout: TimeInterval = codesignTimeout) -> String? {
        guard
            let output = runSubprocess(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["-dv", bundleURL.path],
                timeout: timeout)
        else { return nil }
        return parseTeamIdentifier(from: output)
    }

    static func runSubprocess(
        executableURL: URL, arguments: [String], timeout: TimeInterval = codesignTimeout
    ) -> String? {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = OSAllocatedUnfairLock(initialState: Data())
        let readDone = DispatchGroup()
        readDone.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            output.withLock { $0 = data }
            readDone.leave()
        }
        if finished.wait(timeout: .now() + max(0.01, timeout)) == .timedOut {
            if process.isRunning { process.terminate() }
            _ = finished.wait(timeout: .now() + 0.5)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 0.5)
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.withLock { $0 }, as: UTF8.self)
    }

    private static func parsedHTTPComponents(from raw: String?) -> URLComponents? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return components
    }

    private static func hasNoCredentials(_ components: URLComponents) -> Bool {
        components.user == nil && components.password == nil
            && components.percentEncodedUser == nil && components.percentEncodedPassword == nil
    }
}
