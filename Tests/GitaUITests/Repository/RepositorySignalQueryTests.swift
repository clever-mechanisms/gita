import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// A detached HEAD has no branch: it matches no deployment, not one that has no branch either.
@Suite struct RepositorySignalQueryTests {
    private static let head = String(repeating: "a", count: 40)

    private static func preview(id: String, branch: String?, commit: String?) -> ProviderItem {
        ProviderItem(
            id: id, provider: .vercel, category: "Deployment", title: "fixture", state: .success, detail: "READY",
            commit: commit, branch: branch, date: ProviderSamples.date, kind: .deployment,
            deployment: DeploymentSummary(environment: .preview))
    }

    @Test func aPreviewMatchesOnlyARealBranchOrHead() {
        let unbranched = Self.preview(id: "loose", branch: nil, commit: nil)
        let query = ProviderSignalQuery(signals: [unbranched])
        #expect(query.preview(branch: nil, head: nil) == nil)
        #expect(query.preview(branch: nil, head: Self.head) == nil)
        let branched = Self.preview(id: "main", branch: "main", commit: nil)
        let atHead = Self.preview(id: "head", branch: nil, commit: Self.head)
        let both = ProviderSignalQuery(signals: [unbranched, branched, atHead])
        #expect(both.preview(branch: "main", head: nil)?.id == "main")
        #expect(both.preview(branch: nil, head: Self.head)?.id == "head")
        #expect(both.latestDeployment(branch: nil, head: nil) == nil)
    }
}
