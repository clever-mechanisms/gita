import Foundation
import Testing

@testable import GitaUI

@Suite("Update feed policy")
struct UpdateFeedPolicyTests {
    @Test func productionFeedAndTeamIdentifierConstantsMatchReleaseConfig() {
        #expect(UpdateFeedPolicy.productionFeedURLString == "https://getgita.app/appcast.xml")
        #expect(UpdateFeedPolicy.teamIdentifier == "PCZ6F8Q9DZ")
        #expect(UpdateFeedPolicy.feedOverrideKey == "UpdateFeedURL")
    }

    @Test func releasePolicyAcceptsOnlyStrictLoopbackHTTPAndHTTPS() throws {
        let allowed = [
            "http://localhost:3200/appcast.xml",
            "https://localhost/appcast.xml",
            "  HTTP://LOCALHOST:8080/appcast.xml \n",
            "http://127.0.0.1:4000/appcast.xml",
            "https://127.0.0.1/appcast.xml",
            "http://[::1]:8080/appcast.xml",
            "https://[::1]/appcast.xml",
        ]
        for raw in allowed {
            let url = try #require(UpdateFeedPolicy.validatedFeedOverride(raw, allowAnyHost: false), "Expected \(raw)")
            #expect(url.path == "/appcast.xml")
        }
    }

    @Test func releasePolicyRejectsSpoofedHostsRemoteHostsUserinfoAndBadSchemes() {
        let rejected: [String?] = [
            nil,
            "",
            "   ",
            "not a url",
            "https://getgita.app/appcast.xml",
            "https://evil.example/appcast.xml",
            "http://127.0.0.1.evil.com/appcast.xml",
            "http://localhost.evil.com/appcast.xml",
            "http://[::ffff:127.0.0.1]/appcast.xml",
            "http://127.0.0.2/appcast.xml",
            "http://0.0.0.0/appcast.xml",
            "file:///tmp/appcast.xml",
            "ftp://localhost/appcast.xml",
            "http://user@localhost/appcast.xml",
            "http://user:pass@127.0.0.1:8080/appcast.xml",
            "http://@localhost/appcast.xml",
            "http://:pass@localhost/appcast.xml",
            "https:///appcast.xml",
        ]
        for raw in rejected {
            #expect(
                UpdateFeedPolicy.validatedFeedOverride(raw, allowAnyHost: false) == nil,
                "Expected rejection for \(raw ?? "<nil>")")
        }
    }

    @Test func debugPolicyAllowsValidRemoteHTTPURLsButStillRejectsUnsafeInputs() throws {
        let staging = try #require(
            UpdateFeedPolicy.validatedFeedOverride("https://staging.getgita.app/appcast.xml", allowAnyHost: true))
        #expect(staging.host == "staging.getgita.app")
        #expect(UpdateFeedPolicy.validatedFeedOverride("file:///tmp/appcast.xml", allowAnyHost: true) == nil)
        #expect(
            UpdateFeedPolicy.validatedFeedOverride("https://user@staging.getgita.app/appcast.xml", allowAnyHost: true)
                == nil)
        #expect(
            UpdateFeedPolicy.validatedFeedOverride("https://:secret@localhost/appcast.xml", allowAnyHost: true) == nil)
    }

    @Test func isLoopbackHostMatchesOnlyStrictLoopbackForms() {
        #expect(UpdateFeedPolicy.isLoopbackHost("localhost"))
        #expect(UpdateFeedPolicy.isLoopbackHost("LOCALHOST"))
        #expect(UpdateFeedPolicy.isLoopbackHost("127.0.0.1"))
        #expect(UpdateFeedPolicy.isLoopbackHost("::1"))
        #expect(UpdateFeedPolicy.isLoopbackHost("[::1]"))
        #expect(!UpdateFeedPolicy.isLoopbackHost("127.0.0.1.evil.com"))
        #expect(!UpdateFeedPolicy.isLoopbackHost("localhost.evil.com"))
        #expect(!UpdateFeedPolicy.isLoopbackHost("::ffff:127.0.0.1"))
    }

    @Test func parsesTeamIdentifierFromCodesignOutput() {
        let signed = """
            Executable=/Applications/Gita.app/Contents/MacOS/Gita
            Identifier=dev.clevermechanisms.Gita
            Authority=Developer ID Application: Clever Mechanisms (PCZ6F8Q9DZ)
            TeamIdentifier=PCZ6F8Q9DZ
            """
        #expect(UpdateFeedPolicy.parseTeamIdentifier(from: signed) == "PCZ6F8Q9DZ")

        let adHoc = """
            Identifier=dev.clevermechanisms.Gita
            TeamIdentifier=not set
            """
        #expect(UpdateFeedPolicy.parseTeamIdentifier(from: adHoc) == nil)
        #expect(UpdateFeedPolicy.parseTeamIdentifier(from: "TeamIdentifier=   \n") == nil)
        #expect(UpdateFeedPolicy.parseTeamIdentifier(from: "No team line here") == nil)
    }

    @Test func officialBuildCheckRequiresAppBundleAndMatchingTeamID() {
        let appURL = URL(fileURLWithPath: "/Applications/Gita.app")
        let binaryURL = URL(fileURLWithPath: "/usr/local/bin/Gita")
        var lookupCount = 0
        let nonApp = UpdateFeedPolicy.isOfficialBuild(bundleURL: binaryURL) { _ in
            lookupCount += 1
            return UpdateFeedPolicy.teamIdentifier
        }
        #expect(!nonApp)
        #expect(lookupCount == 0)

        #expect(UpdateFeedPolicy.isOfficialBuild(bundleURL: appURL) { _ in UpdateFeedPolicy.teamIdentifier })
        #expect(!UpdateFeedPolicy.isOfficialBuild(bundleURL: appURL) { _ in "WRONGTEAM1" })
        #expect(!UpdateFeedPolicy.isOfficialBuild(bundleURL: appURL) { _ in nil })
    }

    @Test func readTeamIdentifierReturnsNilForUnsignedDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gita-unsigned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        #expect(UpdateFeedPolicy.readTeamIdentifier(of: tempDir) == nil)
        // Also exercise a real signed system binary to verify successful exit handling.
        _ = UpdateFeedPolicy.readTeamIdentifier(of: URL(fileURLWithPath: "/bin/ls"))
    }
}
