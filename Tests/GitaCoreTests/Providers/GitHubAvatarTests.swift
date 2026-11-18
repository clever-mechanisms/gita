import Foundation
import Testing

@testable import GitaCore

struct GitHubAvatarTests {
    @Test func noreplyAddressesResolveWithoutARequest() {
        #expect(
            GitHubAvatars.noreplyURL(email: "85008132+Rolottr@users.noreply.github.com")?.absoluteString
                == "https://avatars.githubusercontent.com/u/85008132?s=64&v=4")
        #expect(
            GitHubAvatars.noreplyURL(email: "octocat@users.noreply.github.com")?.absoluteString
                == "https://avatars.githubusercontent.com/octocat?s=64")
        #expect(GitHubAvatars.noreplyURL(email: "someone@example.com") == nil)
        #expect(GitHubAvatars.noreplyURL(email: "0+x@users.noreply.github.com") == nil)
        #expect(GitHubAvatars.noreplyURL(email: "../evil@users.noreply.github.com") == nil)
        #expect(GitHubAvatars.noreplyURL(email: "-bad@users.noreply.github.com") == nil)
    }

    @Test func onlyGitHubsAvatarHostOverHTTPSIsAccepted() {
        #expect(GitHubAvatars.validated("https://avatars.githubusercontent.com/u/1?s=64&v=4") != nil)
        #expect(GitHubAvatars.validated("http://avatars.githubusercontent.com/u/1") == nil)
        #expect(GitHubAvatars.validated("https://evil.example/u/1") == nil)
        #expect(GitHubAvatars.validated("https://user:pass@avatars.githubusercontent.com/u/1") == nil)
        #expect(GitHubAvatars.validated("https://avatars.githubusercontent.com:8443/u/1") == nil)
    }

    @Test func historyMapsLowercasedEmailsAndSkipsUnverifiedEntries() throws {
        let json = """
            {"data":{"repository":{"nameWithOwner":"Owner/Repo","defaultBranchRef":{"target":{"history":{"nodes":[
              {"author":{"email":"Dev@Example.com","user":{"avatarUrl":"https://avatars.githubusercontent.com/u/7?s=64"}}},
              {"author":{"email":"dev@example.com","user":{"avatarUrl":"https://avatars.githubusercontent.com/u/8?s=64"}}},
              {"author":{"email":"ghost@example.com","user":null}},
              {"author":{"email":"bad@example.com","user":{"avatarUrl":"https://evil.example/a.png"}}}
            ]}}}}}}
            """
        let envelope = try JSONDecoder().decode(
            GitHubGraphQLEnvelope<GitHubAvatars.Repository>.self, from: Data(json.utf8))
        let map = try GitHubAvatars.parse(
            envelope, repository: try #require(GitHubRepository(nameWithOwner: "owner/repo")))
        #expect(map.count == 1)
        #expect(map["dev@example.com"]?.absoluteString == "https://avatars.githubusercontent.com/u/7?s=64")
        let other = try #require(GitHubRepository(nameWithOwner: "other/repo"))
        #expect(throws: (any Error).self) { try GitHubAvatars.parse(envelope, repository: other) }
    }
}
