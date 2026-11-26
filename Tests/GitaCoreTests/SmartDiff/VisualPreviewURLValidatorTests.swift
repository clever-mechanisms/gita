import Foundation
import Testing

@testable import GitaCore

struct VisualPreviewURLValidatorTests {
    @Test func httpsOnly() {
        for raw in [
            "http://a.test", "file:///tmp/demo", "javascript:noop", "data:text/html,test",
            "https://user@a.test", "https://user:secret@a.test", "https:///no-host",
        ] {
            #expect(VisualPreviewURLValidator.validatedHTTPSURL(URL(string: raw)) == nil)
        }
        #expect(VisualPreviewURLValidator.validatedHTTPSURL(URL(string: "https://a.test")) != nil)
    }

    @Test func routeStaysOnOrigin() throws {
        let base = try #require(URL(string: "https://live.test:8443/old?stale=yes"))
        #expect(VisualPreviewURLValidator.normalizedRoute(" users?q=A#card ") == "/users?q=A#card")
        for input in [
            "//other.test/path?x=1#y", "https://other.test/path", "///other.test", "\\\\other.test",
            "javascript:other", "%2F%2Fother.test", "", "?q=1",
        ] {
            let target = try #require(VisualPreviewURLValidator.resolvedURL(base: base, route: input))
            #expect(target.host == "live.test" && target.port == 8443 && target.scheme == "https")
            #expect(!VisualPreviewURLValidator.normalizedRoute(input).hasPrefix("//"))
        }
        let encoded = try #require(VisualPreviewURLValidator.resolvedURL(base: base, route: "/a%2Fb?q=x%26y#top"))
        #expect(encoded.absoluteString == "https://live.test:8443/a%2Fb?q=x%26y#top")
    }

    @Test func deploymentPair() throws {
        let live = try #require(URL(string: "https://prod.vercel.app"))
        let domain = try #require(URL(string: "https://project.test"))
        let preview = try #require(URL(string: "https://branch.vercel.app"))
        let context = VercelContext(production: .init(deploymentID: "live", url: live, domains: [domain]))
        var deployment = DeploymentDetail(
            id: "pr", projectName: "Demo", state: .success, previewURL: preview, aliases: [])
        let pair = try #require(
            VisualPreviewURLValidator.resolvePair(vercelContext: context, previewDeployment: deployment))
        #expect(pair.productionURL == domain && pair.previewURL == preview)
        var aliased = context
        let stable = try #require(URL(string: "https://feature.vercel.app"))
        deployment.branch = "feature"
        aliased.branchPreviews["feature"] = stable
        aliased.branchPreviewTargets["feature"] = preview.host
        let stablePair = VisualPreviewURLValidator.resolvePair(vercelContext: aliased, previewDeployment: deployment)
        #expect(stablePair?.previewURL == stable)
        aliased.branchPreviewTargets["feature"] = "another.vercel.app"
        let exactPair = VisualPreviewURLValidator.resolvePair(vercelContext: aliased, previewDeployment: deployment)
        #expect(exactPair?.previewURL == preview)
        deployment.id = "live"
        #expect(VisualPreviewURLValidator.resolvePair(vercelContext: context, previewDeployment: deployment) == nil)
        #expect(VisualPreviewURLValidator.resolvePair(vercelContext: nil, previewDeployment: deployment) == nil)
        #expect(VisualPreviewURLValidator.resolvePair(vercelContext: context, previewDeployment: nil) == nil)
    }
}
