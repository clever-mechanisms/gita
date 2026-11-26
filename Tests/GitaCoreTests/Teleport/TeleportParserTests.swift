import Foundation
import Testing

@testable import GitaCore

struct TeleportParserTests {
    @Test(arguments: ["", "/", "/files", "/commits", "/checks", "/files?view=split#diff"])
    func pullRequests(suffix: String) throws {
        let url = try #require(URL(string: "https://github.com/Org/app/pull/73" + suffix))
        let raw = " \n<" + url.absoluteString + ">\n"
        #expect(TeleportParser.parse(raw)?.query == .pullRequest(owner: "Org", repo: "app", number: 73, sourceURL: url))
    }

    @Test(arguments: ["commit/ABCdef0", "pull/4/commits/ABCdef0"])
    func commits(path: String) throws {
        let url = try #require(URL(string: "https://github.com/o/r/" + path))
        #expect(TeleportParser.parse(url: url)?.query == .commit(owner: "o", repo: "r", sha: "abcdef0", sourceURL: url))
    }

    @Test(arguments: ["", "/attempts/2", "/job/100"])
    func actions(suffix: String) throws {
        let url = try #require(URL(string: "https://github.com/o/r/actions/runs/99" + suffix))
        #expect(
            TeleportParser.parse(url: url)?.query
                == .workflowRun(
                    owner: "o", repo: "r", runID: 99,
                    jobID: suffix.contains("job") ? 100 : nil, sourceURL: url))
    }

    @Test func deployments() throws {
        let dash = try #require(URL(string: "https://vercel.com/studio/my-app/abc0123"))
        #expect(
            TeleportParser.parse(url: dash)?.query
                == .deployment(
                    teamSlug: "studio", projectName: "my-app",
                    deploymentRef: "abc0123", sourceURL: dash))
        for host in ["my-app-abc012345-team.vercel.app", "my-app.vercel.app"] {
            let url = try #require(URL(string: "https://" + host))
            #expect(
                TeleportParser.parse(url: url)?.query
                    == .deployment(teamSlug: nil, projectName: "my-app", deploymentRef: host, sourceURL: url))
        }
    }

    @Test(arguments: ["feature/login", "fix-123", "release/v2.0", "origin/main", "refs/heads/main"])
    func branches(name: String) {
        let expected = name.replacingOccurrences(of: "refs/heads/", with: "")
        #expect(TeleportParser.parse(name)?.query == .branch(owner: nil, repo: nil, name: expected))
    }

    @Test func deepLinks() throws {
        let link = "gita://open?workspace=Work&repo=o%2Fr&url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F7"
        let nested = try #require(TeleportParser.parse(link))
        #expect(nested.workspaceHint == "Work" && nested.repoHint == "o/r" && nested.rawInput == link)
        #expect(nested.query == TeleportParser.parse("https://github.com/o/r/pull/7")?.query)
        #expect(
            TeleportParser.parse("gita://open?repo=o/r&pull=7")?.query
                == .pullRequest(owner: "o", repo: "r", number: 7, sourceURL: nil))
        #expect(
            TeleportParser.parse("gita://open?repo=o/r&run=7&job=2")?.query
                == .workflowRun(owner: "o", repo: "r", runID: 7, jobID: 2, sourceURL: nil))
        #expect(TeleportParser.parse("gita://open?ref=main")?.query == .branch(owner: nil, repo: nil, name: "main"))
        #expect(
            TeleportParser.parse("gita://open?deployment=dpl_demo")?.query
                == .deployment(teamSlug: nil, projectName: nil, deploymentRef: "dpl_demo", sourceURL: nil))
        for sha in ["ABc1234", String(repeating: "F", count: 40)] {
            #expect(
                TeleportParser.parse(sha)?.query
                    == .commit(owner: nil, repo: nil, sha: sha.lowercased(), sourceURL: nil))
            #expect(TeleportParser.parse("gita://open?sha=" + sha)?.query == TeleportParser.parse(sha)?.query)
        }
    }

    @Test(arguments: [
        "", "push changes", "-h", "main\0x", "main\nx", "a..b", "r@{3}", "r^", "r~", "r:x", "w?", "r*", "r[", "a\\b",
        "a//b", ".hidden/x", "x.lock", "feature/", "gita://open?branch=%00", "gita://open?sha=--help",
        "gita://open?pr=0&repo=o/r", "gita://open?branch=main&ref=other", "gita://open?branch=x&job=9",
        "x;pwd", "gita://open?branch=%24%28id%29", "gita://open?workspace=-config&ref=main",
        "https://github.com/o/r/pull/1/job",
        "https://github.com/o/r/commit/123",
        "https://github.com/o/r/actions/runs/4/job/0", "https://github.com@other.test/o/r/pull/1",
        "https://evil.vercel.app.example.org", "https://github.com/o/r/pull/1%00", "gita://other?branch=main",
    ])
    func malformed(text: String) { #expect(TeleportParser.parse(text) == nil) }
}
