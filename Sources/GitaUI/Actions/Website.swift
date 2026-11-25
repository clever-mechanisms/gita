import Foundation
import GitaCore

/// Links to the product site, tagged so the site's analytics can tell app visits apart (built by
/// `ProductWebsite`). The host comes from `GITA_WEBSITE_HOST` in `Config/Product.xcconfig` via Info.plist
/// `GitaWebsiteHost` (defaulting to `getgita.app` for unbundled dev runs), never replaced by clevermechanisms.dev.
enum Website {
    static let defaultHost = "getgita.app"
    static let repositoryPath = "clever-mechanisms/gita"
    static let repository = URL(string: "https://github.com/" + repositoryPath)

    static var host: String? {
        if let configured = Bundle.main.object(forInfoDictionaryKey: ProductWebsite.infoKey) as? String {
            return ProductWebsite.host(from: configured)
        }
        return defaultHost
    }
    static func url(_ path: String = "", campaign: String, content: String) -> URL? {
        ProductWebsite.url(host: host, path: path, campaign: campaign, content: content)
    }
    static var home: URL? { url(campaign: "about", content: "website") }
    static var changelog: URL? { ProductWebsite.changelog(host: host) }
    static var support: URL? { ProductWebsite.support(host: host) }
}

/// Gitā's issue tracker on GitHub: a bug report opens a new issue whose body already carries this copy's version line.
enum BugReport {
    static let issues = "https://github.com/clever-mechanisms/gita/issues/new"

    static func url(summary: String = AppInfo.summary) -> URL? {
        var components = URLComponents(string: issues)
        let body = "**What happened**\n\n\n**Steps to reproduce**\n\n\n---\n" + summary
        components?.queryItems = [URLQueryItem(name: "body", value: body)]
        return components?.url
    }
}
