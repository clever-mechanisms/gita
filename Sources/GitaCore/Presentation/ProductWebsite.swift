import Foundation

/// The one place that builds links to the product site:
/// `https://<host>/<path>?utm_source=gita&utm_medium=app&utm_campaign=<feature>&utm_content=<button>`. A browser
/// opened by the app sends no Referer, so untagged visits would count as direct traffic.
public enum ProductWebsite {
    public static let infoKey = "GitaWebsiteHost"
    public static let source = "gita"
    public static let medium = "app"

    /// The product domain from Info.plist, or nil while none is chosen. Never clevermechanisms.dev in its place.
    public static func host(from value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty,
            value.range(
                of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression)
                != nil,
            value != "clevermechanisms.dev", !value.hasSuffix(".clevermechanisms.dev")
        else { return nil }
        return value
    }

    public static func url(host: String?, path: String = "", campaign: String, content: String) -> URL? {
        guard let host = Self.host(from: host) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.queryItems = [
            URLQueryItem(name: "utm_source", value: source),
            URLQueryItem(name: "utm_medium", value: medium),
            URLQueryItem(name: "utm_campaign", value: campaign),
            URLQueryItem(name: "utm_content", value: content),
        ]
        return components.url
    }
}
