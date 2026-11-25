import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("CommitEcosystem UI", .serialized)
@MainActor
struct CommitEcosystemUITests {
    @Test func signatureBadgeViewVisibilityAndPopoverDetails() {
        UITestSupport.bootstrap()
        let badge = SignatureBadgeView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        #expect(badge.isHidden)

        let valid = CommitSignatureInfo(
            status: .valid,
            signer: "Ada Lovelace <ada@example.com>",
            keyID: "9F8E7D6C5B4A3210",
            fingerprint: "0123456789ABCDEF0123456789ABCDEF01234567"
        )
        badge.update(valid)
        #expect(!badge.isHidden)
        #expect(badge.presentation.category == .verified)
        #expect(badge.presentation.title == String(localized: "Verified"))
        badge.layoutSubtreeIfNeeded()
        UITestSupport.render(badge)

        let detailVC = badge.makeDetailViewController()
        detailVC.view.layoutSubtreeIfNeeded()
        #expect(detailVC.view.fittingSize.width >= 300)

        let revoked = CommitSignatureInfo(status: .revokedKey, signer: nil, keyID: nil, fingerprint: nil)
        badge.update(revoked)
        #expect(badge.presentation.category == .invalid)

        badge.update(.unsigned)
        #expect(badge.isHidden)
    }

    @Test func commitSigningSettingsRowLifecycleToggleAndTemplatePreview() {
        UITestSupport.bootstrap()
        let row = CommitSigningSettingsRow(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        let config = CommitSigningConfig(
            isEnabled: false,
            isRepoLocalOverride: true,
            format: .ssh,
            signingKey: "/Users/dev/.ssh/id_ed25519.pub"
        )
        let template = CommitTemplateResult(
            content: "feat: template subject",
            rawContent: "# comment\nfeat: template subject\n",
            sourcePath: URL(fileURLWithPath: "/tmp/repo/.gitmessage"),
            isConfiguredPath: false
        )
        var toggledTo: [Bool] = []
        row.onToggleSigning = { toggledTo.append($0) }

        row.apply(CommitSigningRowState(signing: .loading, template: nil))
        #expect(!row.signingToggle.isEnabled)

        row.apply(CommitSigningRowState(signing: .loaded(config), template: template))
        #expect(!row.templateButton.isHidden)
        #expect(row.signingToggle.isEnabled)
        row.signingToggle.onClick?()
        #expect(toggledTo == [true])

        let previewVC = row.makeTemplatePreviewController(for: template)
        previewVC.view.layoutSubtreeIfNeeded()
        #expect(previewVC.view.fittingSize.height > 150)

        row.apply(CommitSigningRowState(signing: .mutating(config), template: nil))
        #expect(!row.signingToggle.isEnabled)
        #expect(row.templateButton.isHidden)

        row.apply(CommitSigningRowState(signing: .failed("git config unreadable"), template: nil))
        #expect(!row.signingToggle.isEnabled)
        #expect(row.state.signing.errorMessage == "git config unreadable")
    }

    @Test func commitMessageAssistControllerLifecycleTransitions() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let service = GitService(root: repo.url)
        let claude = URL(fileURLWithPath: "/usr/local/bin/claude")
        let expected = GeneratedCommitMessage(
            subject: "Add signing popover",
            body: "Shows signer and fingerprint.",
            agent: .claude
        )

        var applied: [GeneratedCommitMessage] = []
        var observedStates: [CommitMessageDraftState] = []
        let controller = CommitMessageAssistController { _, _, _ in
            try await Task.sleep(for: .milliseconds(15))
            return expected
        }
        controller.onApplyMessage = { applied.append($0) }
        controller.onStateChanged = { observedStates.append($0) }

        controller.updateAvailability(hasStagedChanges: false, installedAgents: [.claude: claude])
        #expect(!controller.buttonPresentation.isEnabled)

        controller.updateAvailability(hasStagedChanges: true, installedAgents: [:])
        #expect(!controller.buttonPresentation.isEnabled)

        controller.updateAvailability(hasStagedChanges: true, installedAgents: [.claude: claude])
        #expect(controller.buttonPresentation.isEnabled)
        #expect(controller.generate(service: service))
        #expect(controller.state == .generating(agent: .claude))
        #expect(controller.buttonPresentation.isGenerating)

        try await waitUntil { controller.state == .ready(expected) }
        #expect(controller.state == .ready(expected))
        #expect(applied == [expected])
        #expect(observedStates.contains(.generating(agent: .claude)))
        #expect(observedStates.contains(.ready(expected)))

        let failingController = CommitMessageAssistController { _, _, _ in
            throw CommitMessageGeneratorError.agentFailed(agent: .claude, detail: "quota reached")
        }
        failingController.updateAvailability(hasStagedChanges: true, installedAgents: [.claude: claude])
        _ = failingController.generate(service: service)
        try await waitUntil { failingController.state.errorMessage != nil }
        #expect(failingController.state.errorMessage?.contains("quota reached") == true)
    }

    @Test func submodulesLFSPresenterPreservesDataOnMutationFailureAndConfirmsForceUnlock() async throws {
        UITestSupport.bootstrap()
        let root = URL(fileURLWithPath: "/tmp/demo-repo", isDirectory: true)
        let submoduleClean = GitSubmodule(
            path: "deps/core",
            name: "core",
            sha: String(repeating: "a", count: 40),
            status: .clean,
            url: "https://example.com/core.git",
            branch: "main"
        )
        let submoduleUninit = GitSubmodule(
            path: "deps/docs",
            name: "docs",
            sha: String(repeating: "b", count: 40),
            status: .uninitialized,
            url: "https://example.com/docs.git"
        )
        let lock = LFSLockEntry(id: "7", path: "art/logo.psd", owner: "Bob", isOwnedByCurrentUser: false)
        let lfsStatus = LFSStatus(
            availability: .available(version: "git-lfs/3.5.1"),
            patterns: [LFSPattern(pattern: "*.psd", source: ".gitattributes")],
            files: [LFSFileEntry(oid: String(repeating: "f", count: 64), path: "art/logo.psd", isDownloaded: true)],
            locks: [lock],
            cacheBytes: 1_048_576
        )

        var forceUnlocked: [String] = []
        let presenter = SubmodulesLFSPresenter(
            repositoryRoot: root,
            actions: .init(
                loadSubmodules: { [submoduleClean, submoduleUninit] },
                initSubmodules: { _, _ in },
                updateSubmodules: { _, _ in },
                syncSubmodules: { _, _ in },
                loadLFS: { lfsStatus },
                lockLFS: { _ in
                    throw CommitMessageGeneratorError.agentFailed(agent: .claude, detail: "lock refused by remote")
                },
                unlockLFS: { path, force in
                    if force {
                        await MainActor.run { forceUnlocked.append(path) }
                    }
                }
            )
        )

        var openedURLs: [URL] = []
        var revealedURLs: [URL] = []
        presenter.onOpenInTab = { openedURLs.append($0) }
        presenter.onRevealInFinder = { revealedURLs.append($0) }

        let windowController = SubmodulesLFSWindowController(presenter: presenter)
        let window = windowController.prepareWindow(initialTab: .submodules)
        #expect(window.title.contains("demo-repo"))

        presenter.loadSubmodules()
        try await waitUntil { !presenter.submoduleState.isLoading }
        #expect(presenter.submoduleState.submodules.count == 2)
        #expect(presenter.submoduleTabBadge == "2")

        presenter.selectedSubmodulePath = "deps/docs"
        #expect(!presenter.canOpenSelectedSubmodule)
        presenter.selectedSubmodulePath = "deps/core"
        #expect(presenter.canOpenSelectedSubmodule)
        presenter.openSubmoduleInTab(submoduleClean)
        presenter.revealSubmoduleInFinder(submoduleClean)
        #expect(openedURLs == [root.appendingPathComponent("deps/core", isDirectory: true).standardizedFileURL])
        #expect(revealedURLs == [root.appendingPathComponent("deps/core", isDirectory: true).standardizedFileURL])

        presenter.selectTab(.lfs)
        try await waitUntil { presenter.lfsState.status != nil }
        #expect(presenter.selectedTab == .lfs)
        #expect(presenter.lfsState.status == lfsStatus)
        #expect(presenter.lfsTabBadge == "1")
        #expect(!SubmodulesLFSPresenter.formattedCacheSize(lfsStatus.cacheBytes).isEmpty)

        // Failed lock keeps the loaded LFS files intact while exposing errorMessage.
        presenter.lockLFSFile(path: "art/logo.psd")
        try await waitUntil { !presenter.lfsState.isBusy }
        #expect(presenter.lfsState.status?.files.count == 1)
        #expect(presenter.lfsState.errorMessage?.contains("lock refused by remote") == true)

        // Force Unlock goes through confirmation before mutating, and cancelReads() does not abort it.
        let lfsTab = LFSTabView(presenter: presenter)
        var promptedOwners: [String] = []
        lfsTab.confirmForceUnlock = { entry, proceed in
            promptedOwners.append(entry.owner)
            proceed()
        }
        lfsTab.requestForceUnlock(lock)
        presenter.cancelReads()
        try await waitUntil { !forceUnlocked.isEmpty && !presenter.lfsState.isBusy }
        #expect(promptedOwners == ["Bob"])
        #expect(forceUnlocked == ["art/logo.psd"])
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
