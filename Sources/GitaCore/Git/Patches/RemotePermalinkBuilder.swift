import Foundation

public enum RemotePermalinkBuilder {
    public static func commitURL(remote: String, sha: String) -> URL? {
        guard let (page, host) = repository(remote), validSegment(sha) else { return nil }
        let route: String
        switch host {
        case .github: route = "commit"
        case .gitlab: route = "-/commit"
        case .bitbucket: route = "commits"
        default: return nil
        }
        return makeURL(page, route: route, ref: sha, path: [], fragment: nil)
    }

    public static func fileURL(remote: String, ref: String, path: String, lines: ClosedRange<Int>? = nil) -> URL? {
        let components = path.components(separatedBy: "/")
        guard let (page, host) = repository(remote), (lines?.lowerBound ?? 1) > 0,
            ref.components(separatedBy: "/").allSatisfy(validSegment), components.allSatisfy(validSegment)
        else { return nil }
        let route: String
        switch host {
        case .github: route = "blob"
        case .gitlab: route = "-/blob"
        case .bitbucket: route = "src"
        default: return nil
        }
        return makeURL(page, route: route, ref: ref, path: components, fragment: lines.map { anchor($0, host: host) })
    }

    private static func repository(_ remote: String) -> (URL, RemoteWebPage.Host)? {
        guard !GitInput.containsControlCharacters(remote) else { return nil }
        let path: String
        if remote.contains("://") {
            guard let parts = URLComponents(string: remote), let scheme = parts.scheme?.lowercased(),
                ["https", "http", "ssh"].contains(scheme), parts.path.hasPrefix("/")
            else { return nil }
            path = String(parts.path.dropFirst())
        } else {
            guard let colon = remote.firstIndex(of: ":") else { return nil }
            path = String(remote[remote.index(after: colon)...])
        }
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard normalized.components(separatedBy: "/").allSatisfy(validSegment),
            let page = RemoteWebPage.repository(remote),
            page.pathComponents.dropFirst().allSatisfy(validSegment)
        else { return nil }
        return (page, RemoteWebPage.host(of: page))
    }

    private static func validSegment(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !GitInput.containsControlCharacters(value)
    }

    private static func makeURL(_ page: URL, route: String, ref: String, path: [String], fragment: String?) -> URL? {
        var parts = URLComponents(url: page, resolvingAgainstBaseURL: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let segments = ([ref] + path).compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
        guard segments.count == path.count + 1 else { return nil }
        parts?.percentEncodedPath += "/" + route + "/" + segments.joined(separator: "/")
        parts?.fragment = fragment
        return parts?.url
    }

    private static func anchor(_ lines: ClosedRange<Int>, host: RemoteWebPage.Host) -> String {
        let start = String(lines.lowerBound)
        let end = String(lines.upperBound)
        let single = lines.lowerBound == lines.upperBound
        switch host {
        case .bitbucket: return "lines-" + start + (single ? "" : ":" + end)
        case .gitlab: return "L" + start + (single ? "" : "-" + end)
        default: return "L" + start + (single ? "" : "-L" + end)
        }
    }
}
