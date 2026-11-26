import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite("CRAP coverage · GitaUI")
struct CRAPUICoverageTests {
    @Test func enumsPresentersAndBadgesCoverAllCases() {
        for filter in CleanupFilter.allCases {
            #expect(!filter.title.isEmpty)
        }
        let badges: [CleanupBadge] = [
            .merged, .goneUpstream, .stale, .unmergedWarning, .dirtyWarning, .prunable, .failed,
        ]
        for badge in badges {
            #expect(!badge.title.isEmpty)
        }
        for kind in ReflogActionKind.allCases {
            #expect(!ReflogActionBadge.badge(for: kind).title.isEmpty)
        }

        let steps = [
            GitRebaseAction.pick, .reword, .edit, .squash, .fixup, .drop,
        ].enumerated().map { idx, action in
            RebaseStepPrediction(
                commitID: "abcdef012345\(idx)", action: action, outcome: .clean, resultingTreeID: "tree\(idx)")
        }
        let sim = RebaseSimulationResult(steps: steps, finalTreeID: "tree5")
        let rows = SpeculativePreviewContent.rebase(sim).steps
        #expect(rows.count == 6)
        #expect(rows.allSatisfy { !$0.title.isEmpty })

        let presenter = ExternalToolsPresenter()
        #expect(presenter.validation(.init(preset: .fileMerge), kind: .diff, detection: nil) != nil)
        #expect(
            presenter.validation(
                .init(preset: .fileMerge), kind: .diff, detection: .installed(executablePath: "/usr/bin/opendiff"))
                == nil)
        #expect(
            presenter.validation(
                .init(preset: .fileMerge), kind: .merge, detection: .installed(executablePath: "/usr/bin/opendiff"))
                == nil)
        #expect(
            presenter.validation(
                .init(preset: .custom, customExecutable: "", customArguments: []), kind: .diff, detection: nil) != nil)
        #expect(presenter.banner(.idle).isEmpty)
        #expect(!presenter.banner(.launching).isEmpty)
        #expect(!presenter.banner(.launched(toolName: "Diff")).isEmpty)
        #expect(presenter.banner(.failed("err")) == "err")
    }

    @Test func smartDiffSnapshotEquatable() {
        let doc = UnifiedDiff.parse("@@ -1,1 +1,1 @@\n-old\n+new\n")
        let filtered = FilteredDiffResult(hiddenNoiseHunkIndices: [], collapsedNoiseRuns: [])
        let snap1 = SmartDiffSnapshot(
            document: doc, filtered: filtered, moves: .empty, structured: .unsupported,
            filePath: "a.swift", options: SmartDiffOptions(), expandedNoiseHunks: [],
            displayRows: [], documentIndices: [:])
        let snap2 = SmartDiffSnapshot(
            document: doc, filtered: filtered, moves: .empty, structured: .unsupported,
            filePath: "b.swift", options: SmartDiffOptions(), expandedNoiseHunks: [0],
            displayRows: [], documentIndices: [0: 0])
        let snap1Copy = snap1
        #expect(snap1 == snap1Copy)
        #expect(snap1 != snap2)
    }

    @Test func menuBarTriageMapperCoversAllAttentionKinds() throws {
        let repoURL = URL(fileURLWithPath: "/tmp/triage-repo")
        let suiteName = "CRAPUICoverage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var state = MenuPanelState()
        state.workspaces = [
            .init(id: "ws-1", title: "Main", presence: .front, repositories: [MenuPanelState.Repository.id(repoURL)])
        ]
        state.names = [ProviderActivity.key(repoURL): "TriageRepo"]
        state.attention = [
            .init(
                id: "1", kind: .agentWaiting(tool: .claudeCode, session: "s1"),
                repository: repoURL, detail: "Waiting"),
            .init(
                id: "2", kind: .reviewRequested, repository: repoURL, detail: "PR",
                url: URL(string: "https://github.com/acme/demo/pull/42")),
            .init(
                id: "3", kind: .reviewRequested, repository: repoURL, detail: "Bad PR", url: nil),
            .init(
                id: "4", kind: .checksFailed, repository: repoURL, detail: "CI",
                url: URL(string: "https://github.com/acme/demo/actions/runs/99")),
            .init(
                id: "5", kind: .checksFailed, repository: repoURL, detail: "Bad CI", url: nil),
            .init(id: "6", kind: .conflicts, repository: repoURL, detail: "Conflicts"),
        ]
        let items = MenuBarTriageMapper.items(from: state, defaults: defaults)
        #expect(items.count == 3)
    }

    @Test func storageHealthViewAndOutlineMenu() {
        #expect(StorageHealthView.banner(.idle) == nil)
        #expect(StorageHealthView.banner(.running("Running")) != nil)
        #expect(StorageHealthView.banner(.succeeded("Done")) != nil)
        #expect(StorageHealthView.banner(.failed("Err")) != nil)

        var invoked: [StorageHealthAction] = []
        let cards = [
            StorageHealthCardModel(
                title: "Untracked", detail: "Cache", action: .untrackedCache(true),
                control: .toggle(true), enabled: true),
            StorageHealthCardModel(
                title: "GC", detail: "Prune", action: .garbageCollection(pruneNow: false),
                control: .button, enabled: true),
        ]
        let view = StorageHealthView(cards: cards, actionState: .running("Working")) { invoked.append($0) }
        #expect(view.documentView != nil)

        let outline = StorageOutlineView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let wt = GitWorktree(path: "/tmp/wt", branch: "feat", head: "111")
        let checkout = CheckoutStorageReport(
            path: URL(fileURLWithPath: "/tmp/wt"), isMainWorktree: false, worktree: wt,
            totalAllocatedBytes: 100, totalLogicalBytes: 100, fileCount: 1, heavyFolders: [], lastModifiedDate: nil)
        let entry = HeavyFolderEntry(
            relativePath: "node_modules", url: URL(fileURLWithPath: "/tmp/wt/node_modules"),
            category: .javascript, status: .reclaimable, allocatedBytes: 100, fileCount: 1)
        let node = StorageOutlineNode(
            title: "wt", url: checkout.path, bytes: 100, checkout: checkout, entry: entry)
        outline.display([node])
        let menu = NSMenu()
        outline.menuNeedsUpdate(menu)
        #expect(menu.items.isEmpty)
        if let nsOutline = outline.documentView as? NSOutlineView {
            nsOutline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            outline.menuNeedsUpdate(menu)
            #expect(menu.items.count == 3)
        }
    }

    @Test func submodulesPresenterMutationPaths() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let sub = GitSubmodule(
            path: "libs/a", name: "a", sha: "1111111", status: .uninitialized,
            url: "https://example.com/a.git", branch: "main")
        let failBox = LockedFlag()
        let actions = SubmodulesLFSActions(
            loadSubmodules: { [sub] },
            initSubmodules: { _, _ in if failBox.value { throw Boom() } },
            updateSubmodules: { _, _ in },
            syncSubmodules: { _, _ in },
            loadLFS: { LFSStatus(availability: .unavailable, patterns: [], files: [], locks: [], cacheBytes: 0) },
            lockLFS: { _ in },
            unlockLFS: { _, _ in }
        )
        let presenter = SubmodulesLFSPresenter(repositoryRoot: URL(fileURLWithPath: "/tmp/repo"), actions: actions)
        presenter.loadSubmodules()
        await appWaitUntil { !presenter.submoduleState.isBusy && !presenter.submoduleState.submodules.isEmpty }
        presenter.initializeSubmodules(path: "libs/a")
        await appWaitUntil { !presenter.submoduleState.isBusy }
        failBox.value = true
        presenter.initializeSubmodules(path: "libs/a")
        await appWaitUntil { presenter.submoduleState.errorMessage != nil }
        #expect(presenter.submoduleState.errorMessage == "boom")
    }

    @Test func narrativeOrderHeaderKeyDownTogglesCollapseState() throws {
        UITestSupport.bootstrap()
        let entry = NarrativeFileEntry(path: "Sources/App.swift", additions: 2, deletions: 1)
        let group = NarrativeFileGroup(
            layer: .coreLogic, entries: [entry], mode: .narrative, collapsedByDefault: false)
        let presenter = NarrativeOrderPresenter()
        var toggles = 0
        let header = NarrativeOrderHeaderView(group: group, presenter: presenter) { toggles += 1 }
        func send(_ keyCode: UInt16, chars: String = "") throws {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                    keyCode: keyCode))
            header.keyDown(with: event)
        }
        try send(KeyPress.leftArrow)
        #expect(presenter.isCollapsed(.coreLogic))
        #expect(toggles == 1)
        try send(KeyPress.rightArrow)
        #expect(!presenter.isCollapsed(.coreLogic))
        #expect(toggles == 2)
        try send(KeyPress.space, chars: " ")
        #expect(presenter.isCollapsed(.coreLogic))
        #expect(toggles == 3)
        try send(0, chars: "a")
        #expect(toggles == 3)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
