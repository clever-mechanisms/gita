import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Safe drag and drop (§6d)", .serialized)
struct SafeDragAndDropTests {
    @Test func foreignAndMixedRepositoryItemsAreRejectedTogether() {
        let references: [GitaDragReference] = [
            .files(paths: ["README.md"], staged: false),
            .branch(fullName: "refs/heads/main", name: "main", isRemote: false),
            .commits(ids: ["abc"]),
        ]
        let items = references.map { $0.pasteboardItem(repositoryRoot: "/A") }
        #expect(GitaDragReference.readAll(from: items, repositoryRoot: "/A") == references)
        #expect(GitaDragReference.readAll(from: items, repositoryRoot: "/B").isEmpty)
        let mixed = items + [references[0].pasteboardItem(repositoryRoot: "/B")]
        #expect(GitaDragReference.readAll(from: mixed, repositoryRoot: "/A").isEmpty)
    }

    @Test func dragReferenceRoundTripAndFileURLExport() {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        let fileURL = URL(fileURLWithPath: "/tmp/example.swift")
        let fileItem = GitaDragReference.files(paths: ["Sources/a.swift"], staged: false)
            .pasteboardItem(repositoryRoot: "/repo", fileURL: fileURL)
        let branchItem = GitaDragReference.branch(
            fullName: "refs/heads/feature", name: "feature", isRemote: false
        ).pasteboardItem(repositoryRoot: "/repo")
        let commitsItem = GitaDragReference.commits(ids: ["abc", "def"]).pasteboardItem(repositoryRoot: "/repo")

        pb.clearContents()
        pb.writeObjects([fileItem])
        #expect(
            GitaDragReference.mergedFiles(from: pb.pasteboardItems ?? [], repositoryRoot: "/repo")?.paths == [
                "Sources/a.swift"
            ])
        #expect(GitaDragReference.mergedFiles(from: pb.pasteboardItems ?? [], repositoryRoot: "/repo")?.staged == false)
        let exportedURLs = pb.pasteboardItems?.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
        #expect(exportedURLs == [fileURL])

        pb.clearContents()
        pb.writeObjects([branchItem])
        #expect(
            GitaDragReference.firstBranch(from: pb.pasteboardItems ?? [], repositoryRoot: "/repo")?.fullName
                == "refs/heads/feature")

        pb.clearContents()
        pb.writeObjects([commitsItem])
        #expect(GitaDragReference.commitIDs(from: pb.pasteboardItems ?? [], repositoryRoot: "/repo") == ["abc", "def"])
    }

    @Test func unstagedToStagedFileDragStagesAndExportsFileURL() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        try fixture.repository.write("Sources/app.swift", "let answer = 123\n")
        try await fixture.refresh()

        controller.model.section = .changes
        try await fixture.wait("changes shown") {
            controller.filePane.unstaged.list.hasFiles
        }

        let unstagedList = controller.filePane.unstaged.list
        let stagedList = controller.filePane.staged.list
        let fileRow = unstagedList.outline.numberOfRows > 1 ? 1 : 0
        let firstItem = try #require(unstagedList.outline.item(atRow: fileRow))
        let writer = try #require(unstagedList.outlineView(unstagedList.outline, pasteboardWriterForItem: firstItem))

        let items = [try #require(writer as? NSPasteboardItem)]

        // Dropping onto same side is rejected; dropping onto Staged is accepted.
        #expect(!unstagedList.canAcceptDrop(from: items))
        #expect(stagedList.canAcceptDrop(from: items))
        let other = try await RepositoryWindowFixture()
        defer { other.close() }
        let otherList = other.controller.filePane.staged.list
        #expect(!otherList.canAcceptDrop(from: items))
        #expect(!otherList.acceptDrop(from: items))
        let exported = items.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
        #expect(exported.first?.lastPathComponent == "app.swift" || exported.first?.lastPathComponent == "Sources")

        #expect(stagedList.acceptDrop(from: items))
        try await fixture.settle()
        try await fixture.wait("file staged by drop") {
            fixture.model.snapshot?.changes.first(where: { $0.path == "Sources/app.swift" })?.isStaged == true
        }
    }

    @Test func branchAndCommitDropsShowMenusAndSheetsWithoutSilentMutation() async throws {
        let fixture = try await RepositoryWindowFixture { repo in
            try RepositoryWindowFixture.threeCommits(repo)
            try repo.git("checkout", "-q", "-b", "feature/drop")
            try repo.commit("feature.txt", "feat\n", message: "Feature drop")
            try repo.git("checkout", "-q", "main")
        }
        defer { fixture.close() }
        let controller = fixture.controller
        let mainRef = try #require(fixture.model.snapshot?.references.first { $0.name == "main" })
        let featureRef = try #require(fixture.model.snapshot?.references.first { $0.name == "feature/drop" })
        let headBefore = fixture.model.snapshot?.head

        // Branch -> Branch drop shows confirmation menu and opens existing review sheet on choice.
        let dropMenu = try #require(controller.branchDropMenu(sourceFullName: featureRef.fullName, target: mainRef))
        #expect(dropMenu.item(titled: "Merge feature/drop into main…") != nil)
        #expect(dropMenu.item(titled: "Rebase main onto feature/drop…") != nil)
        #expect(fixture.model.snapshot?.head == headBefore)

        try #require(dropMenu.item(titled: "Merge feature/drop into main…")).perform()
        #expect(fixture.commands.calls.contains("mergeReference refs/heads/feature/drop"))
        try #require(dropMenu.item(titled: "Rebase main onto feature/drop…")).perform()
        #expect(fixture.commands.calls.contains("rebaseOntoReference refs/heads/feature/drop"))

        // Commit(s) -> Branch drop opens confirmation sheet without mutating HEAD when cancelled.
        let commits = controller.historyCommits
        let sidebarList = controller.sidebarView.repositoryPane.list
        let mainRow = try #require(
            sidebarList.rows.firstIndex {
                if case .reference(let row) = $0 { return row.reference.fullName == mainRef.fullName }
                return false
            })
        let root = try #require(fixture.model.snapshot?.root)
        let items = [
            GitaDragReference.commits(ids: [commits[0].id, commits[1].id])
                .pasteboardItem(repositoryRoot: root.standardizedFileURL.path)
        ]
        let foreign = [
            GitaDragReference.branch(fullName: featureRef.fullName, name: featureRef.name, isRemote: false)
                .pasteboardItem(repositoryRoot: "/other")
        ]
        #expect(sidebarList.dropOperation(for: foreign, row: mainRow).isEmpty)
        #expect(!sidebarList.acceptDrop(from: foreign, row: mainRow))
        #expect(controller.pillDropOperation(for: foreign).isEmpty)
        #expect(!controller.handlePillDrop(items: foreign, anchor: controller.view))
        #expect(sidebarList.dropOperation(for: items, row: mainRow) == .copy)

        RepositoryWindowFixture.alerts.removeAll()
        RepositoryWindowFixture.alertResponse = .alertSecondButtonReturn
        #expect(sidebarList.acceptDrop(from: items, row: mainRow))
        #expect(RepositoryWindowFixture.alerts.last?.contains("Cherry-pick 2 commits onto main?") == true)
        #expect(fixture.model.snapshot?.head == headBefore)

        // Branch -> non-current Branch drop presents switch-and-operate confirmation without mutating when cancelled.
        let otherPlan = SidebarDropMenuBuilder.BranchDropPlan(
            repositoryRoot: root, sourceName: "topic-a", targetName: "topic-b",
            sourceFullName: "refs/heads/topic-a", targetFullName: "refs/heads/topic-b",
            targetIsCurrent: false, sourceIsCurrent: false)
        RepositoryWindowFixture.alerts.removeAll()
        controller.confirmDroppedBranchOperation(otherPlan, rebase: false)
        #expect(RepositoryWindowFixture.alerts.last?.contains("Merge topic-a into topic-b?") == true)
        #expect(fixture.model.snapshot?.head == headBefore)
    }
}
