import Foundation
import Testing

@testable import GitaCore

@Suite("CommitEcosystem Signing & Templates")
struct CommitSigningTests {
    @Test func signatureStatusMappingAndCategories() {
        let cases: [(String, CommitSignatureStatus, CommitSignatureStatus.BadgeCategory)] = [
            ("G", .valid, .verified),
            ("B", .bad, .invalid),
            ("U", .unknownValidity, .unverified),
            ("X", .expired, .unverified),
            ("Y", .expiredKey, .unverified),
            ("R", .revokedKey, .invalid),
            ("E", .cannotCheck, .unverified),
            ("N", .none, .unsigned),
            ("", .none, .unsigned),
            ("?", .none, .unsigned),
        ]
        for (code, expectedStatus, expectedCategory) in cases {
            let status = CommitSignatureStatus(gitCode: code)
            #expect(status == expectedStatus)
            #expect(status.badgeCategory == expectedCategory)
            #expect(!status.badgeTitle.isEmpty)
            #expect(!status.statusDescription.isEmpty)
        }
    }

    @Test func parseCommitSignaturePayload() {
        let payload = "G\0Jane Doe <jane@example.com>\0ABCD1234EF567890\011223344556677889900AABBCCDDEEFF\n"
        let validData = Data(payload.utf8)
        let info = GitService.parseCommitSignature(validData)
        #expect(info.status == .valid)
        #expect(info.isSigned)
        #expect(info.signer == "Jane Doe <jane@example.com>")
        #expect(info.keyID == "ABCD1234EF567890")
        #expect(info.fingerprint == "11223344556677889900AABBCCDDEEFF")

        let unsignedData = Data("N\0\0\0\n".utf8)
        #expect(GitService.parseCommitSignature(unsignedData) == .unsigned)
        #expect(GitService.parseCommitSignature(Data()) == .unsigned)
    }

    @Test func signingConfigAndRepoLocalToggleAndShowSignatureSafety() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("hello.txt", "hello\n")
        let sha = try await fixture.commit("Initial commit")

        try await fixture.git(["config", "--local", "log.showSignature", "true"])
        let signature = try await fixture.service.commitSignature(for: sha)
        #expect(signature == .unsigned)

        try await fixture.git(["config", "--local", "gpg.format", "ssh"])
        try await fixture.git(["config", "--local", "user.signingkey", "/Users/dev/.ssh/id_ed25519.pub"])

        try await fixture.service.setLocalCommitSigning(true)
        let enabledConfig = try await fixture.service.signingConfig()
        #expect(enabledConfig.isEnabled)
        #expect(enabledConfig.isRepoLocalOverride)
        #expect(enabledConfig.format == .ssh)
        #expect(enabledConfig.signingKey != nil)
        #expect(enabledConfig.shortKeyDisplay == "id_ed25519.pub")

        try await fixture.service.setLocalCommitSigning(false)
        let disabledConfig = try await fixture.service.signingConfig()
        #expect(!disabledConfig.isEnabled)
        #expect(disabledConfig.isRepoLocalOverride)
    }

    @Test func templateStripCommentsHandlesCustomPrefixAndParagraphs() {
        let raw = """
            # Leading comment

            feat(core): add signing badges

            # Explain why below:
            Shows GPG and SSH verification status.

            # Trailing comment
            """
        let stripped = CommitTemplateLoader.stripComments(raw)
        #expect(stripped == "feat(core): add signing badges\n\nShows GPG and SSH verification status.")

        let semicolonRaw = "; comment\nSubject line\n; another\nBody line\n"
        #expect(CommitTemplateLoader.stripComments(semicolonRaw, commentChar: ";") == "Subject line\nBody line")
        #expect(CommitTemplateLoader.stripComments("# only comments\n\n").isEmpty)
    }

    @Test func templateLoaderPrefersConfiguredTemplateRejectsSymlinksAndOversizedFiles() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }

        #expect(await CommitTemplateLoader.load(service: fixture.service) == nil)

        // Symlink .gitmessage must be rejected so repos cannot leak arbitrary host files.
        let outsideFile = fixture.container.appendingPathComponent("secret.txt")
        try Data("SECRET_KEY_MATERIAL\n".utf8).write(to: outsideFile)
        let symlinkPath = fixture.root.appendingPathComponent(".gitmessage")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: outsideFile)
        #expect(await CommitTemplateLoader.load(service: fixture.service) == nil)
        try FileManager.default.removeItem(at: symlinkPath)

        // Regular .gitmessage works as fallback.
        try fixture.write(".gitmessage", "# Repo default\nchore: repo template\n")
        let fallback = await CommitTemplateLoader.load(service: fixture.service)
        #expect(fallback?.isConfiguredPath == false)
        #expect(fallback?.displayName == ".gitmessage")
        #expect(fallback?.content == "chore: repo template")

        // Configured commit.template takes precedence.
        try fixture.write("templates/commit.txt", "# Configured\nfeat: configured template\n")
        try await fixture.git(["config", "--local", "commit.template", "templates/commit.txt"])
        let configured = await CommitTemplateLoader.load(service: fixture.service)
        #expect(configured?.isConfiguredPath == true)
        #expect(configured?.displayName == "commit.txt")
        #expect(configured?.content == "feat: configured template")

        // Oversized templates (> maxTemplateBytes) are refused.
        let oversized = Data(repeating: 0x41, count: CommitTemplateLoader.maxTemplateBytes + 64)
        try fixture.write("templates/commit.txt", data: oversized)
        #expect(await CommitTemplateLoader.load(service: fixture.service) == nil)
    }
}
