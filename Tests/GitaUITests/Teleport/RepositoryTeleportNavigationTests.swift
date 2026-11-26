import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
struct RepositoryTeleportNavigationTests {
    @Test func destinationsSelectTheRepositorySectionAndDeepLinksFocusLocalBranches() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let head = try repo.commit("file", "first\n", message: "First")
        let shell = AppShellHarness(arguments: ["Gita", "--repository", repo.url.path])
        await shell.launch(waitingFor: repo.url)
        defer { shell.tearDown() }
        let app = shell.app
        let targets: [(TeleportTarget, Section)] = [
            (.pullRequest(number: 7, owner: "org", repo: "repo", url: nil), .pullRequests),
            (.workflowRun(runID: 42, jobID: nil, owner: "org", repo: "repo", url: nil), .workflows),
            (.deployment(reference: "deploy", projectName: nil, url: nil), .deployments),
            (.commit(sha: head, url: nil), .history),
        ]
        for (target, section) in targets {
            app.navigate(
                to: TeleportDestination(
                    workspaceID: app.place.workspace.id, workspaceTitle: "Work", repoPath: repo.url,
                    repoDisplayName: "Repo", target: target, matchReason: .localObject))
            #expect(app.model.section == section)
        }
        #expect(app.model.selectedCommit?.id == head)
        #expect(!app.handleTeleportDeepLink(repo.url))
        let link = try #require(URL(string: "gita://open?ref=main"))
        #expect(app.handleTeleportDeepLink(link))
        await appWaitUntil(timeout: .seconds(5)) { app.model.focusedReference?.name == "main" }
    }

    @Test func quickLookStepsWithinTheChangedFileListAndOpensTheSelectedFile() async throws {
        UITestSupport.bootstrap()
        let fixture = try await RepositoryWindowFixture { repo in
            try repo.commit("base", "base\n", message: "Base")
            try repo.write("first", "one\n")
            try repo.write("second", "two\n")
        }
        defer { fixture.close() }
        let controller = fixture.controller
        let model = fixture.model
        model.section = .changes
        let changes = try #require(model.snapshot?.changes.filter(\.isUnstaged))
        try #require(changes.count == 2)
        controller.chooseChange(changes[0], staged: false)
        let facade = controller.quickLookFacade
        defer { facade.closeQuickLook() }
        controller.filePane.unstaged.list.outline.onSpace?()
        try #require(facade.isQuickLookVisible)
        facade.onQuickLookNavigate?(.previous)
        #expect(model.selectedFile == changes[0])
        facade.onQuickLookNavigate?(.next)
        #expect(model.selectedFile == changes[1])
        facade.onQuickLookNavigate?(.next)
        #expect(model.selectedFile == changes[1])
        facade.onQuickLookNavigate?(.previous)
        #expect(model.selectedFile == changes[0])
        facade.onQuickLookOpenFull?(
            .changedFile(
                repoPath: fixture.repository.url, path: changes[1].path, staged: false, statusCode: .untracked))
        #expect(model.section == .changes && model.selectedFile == changes[1])
    }
}
