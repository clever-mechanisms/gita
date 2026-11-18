import Foundation

/// Whether one remote can be edited and fetched here, from its configuration alone. Anything the app cannot
/// represent exactly (inherited or included settings, several URLs, credentials, custom tracking) is read-only.
struct RemoteRestriction {
    private static let plainKeys: Set<String> = [
        "url", "pushurl", "fetch", "push", "tagopt", "prune", "prunetags", "skipdefaultupdate", "skipfetchall",
    ]
    private static let fetchKeys = plainKeys.union([
        "promisor", "partialclonefilter", "followremotehead", "serveroption",
    ])

    var name: String
    var catalog: RemoteCatalog
    /// URLs as configured, and as Git resolves them (`insteadOf` applied).
    var rawFetch: [String]
    var rawPush: [String]
    var fetchURLs: [String]
    var pushURLs: [String]
    var symbolicTrackingIsSafe: Bool

    private var selected: [RemoteConfigEntry] { catalog.entries(ofRemote: name) }

    /// The branches that push to or track this remote, and `remote.pushdefault` when it names it.
    var mappings: [RemoteConfigEntry] {
        let affected = Set(
            catalog.entries.filter {
                ["remote", "pushremote"].contains($0.variable) && $0.branchName != nil && $0.value == name
            }.compactMap(\.branchName))
        return catalog.entries.filter {
            $0.branchName.map(affected.contains) ?? ($0.key == "remote.pushdefault" && $0.value == name)
        }
    }

    private var safeFetchURLs: Bool {
        !fetchURLs.isEmpty && !rawFetch.isEmpty && (rawFetch + fetchURLs).allSatisfy(RemoteURLPolicy.isAccepted)
    }

    private var safePushURLs: Bool { (rawPush + pushURLs).allSatisfy(RemoteURLPolicy.isAccepted) }

    var canFetch: Bool {
        safeFetchURLs && trackingIsSafe && symbolicTrackingIsSafe
            && selected.allSatisfy { Self.fetchKeys.contains($0.variable) }
    }

    /// Nil when the remote can be edited; otherwise why not.
    var message: String? {
        if !catalog.canWriteLocal || selected.isEmpty || !(selected + mappings).allSatisfy(\.local) {
            return String(localized: "Inherited, included or non-local remote settings are read-only here.")
        }
        if rawFetch.count != 1 || !safeFetchURLs || !safePushURLs {
            return String(localized: "Multiple fetch URLs or credential-bearing URL settings are read-only here.")
        }
        if !symbolicTrackingIsSafe {
            return String(
                localized: """
                    A symbolic tracking reference is unsafe or unresolved. Repair it with Git before changing this \
                    remote.
                    """)
        }
        if !trackingIsSafe || !selected.allSatisfy({ Self.plainKeys.contains($0.variable) }) {
            return String(localized: "This remote's custom tracking settings require Git's configuration editor.")
        }
        return nil
    }

    /// Ordinary branch tracking into this remote's own namespace, which no other remote's name or refspec overlaps.
    var trackingIsSafe: Bool {
        let prefix = "refs/remotes/" + name + "/"
        guard !catalog.names.contains(where: { $0 != name && ($0.hasPrefix(name + "/") || name.hasPrefix($0 + "/")) })
        else { return false }
        let specifications = selected.filter { $0.variable == "fetch" }.map(\.value)
        guard !specifications.isEmpty, specifications.allSatisfy({ Self.isPlainTracking($0, prefix: prefix) }) else {
            return false
        }
        return !catalog.entries.contains { entry in
            guard entry.remoteName != name, entry.remoteName != nil, entry.variable == "fetch",
                let spec = FetchRefspec(entry.value), let destination = spec.destination,
                let fixed = spec.destinationPrefix
            else { return false }
            return destination.hasPrefix(prefix) || prefix.hasPrefix(fixed)
        }
    }

    /// `[+]refs/heads/<x>:<prefix><y>` with matching single wildcards, or a negative `^refs/heads/…`.
    static func isPlainTracking(_ specification: String, prefix: String) -> Bool {
        guard !specification.contains(where: \.isWhitespace) else { return false }
        if specification.hasPrefix("^") {
            return specification.hasPrefix("^refs/heads/") && !specification.contains(":")
        }
        let value = specification.hasPrefix("+") ? String(specification.dropFirst()) : specification
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].hasPrefix("refs/heads/"), parts[1].hasPrefix(prefix),
            parts[1].count > prefix.count
        else { return false }
        let wildcards = parts[0].filter { $0 == "*" }.count
        return wildcards == parts[1].filter({ $0 == "*" }).count && wildcards <= 1
    }
}
