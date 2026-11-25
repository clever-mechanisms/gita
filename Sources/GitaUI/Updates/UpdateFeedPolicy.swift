import Foundation

/// Policy for Sparkle 2's ungated update feed (`https://getgita.app/appcast.xml`) and official-build checks.
/// Free/MIT updates carry no license headers and never touch the Keychain or Security framework.
enum UpdateFeedPolicy {
    static let productionFeedURLString = "https://getgita.app/appcast.xml"
    static let teamIdentifier = "PCZ6F8Q9DZ"
    static let feedOverrideKey = "UpdateFeedURL"

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

    /// True only for a `.app` bundle signed with the Clever Mechanisms Developer ID Team Identifier.
    static func isOfficialBuild(
        bundleURL: URL = Bundle.main.bundleURL,
        teamIdentifierLookup: (URL) -> String? = readTeamIdentifier
    ) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        return teamIdentifierLookup(bundleURL) == teamIdentifier
    }

    /// Reads the bundle's signing team identifier via `/usr/bin/codesign` without linking `Security`.
    static func readTeamIdentifier(of bundleURL: URL) -> String? {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", bundleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do {
            try process.run()
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return parseTeamIdentifier(from: String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
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
