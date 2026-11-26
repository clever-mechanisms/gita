import AppKit
import Testing
import os

@testable import GitaCore
@testable import GitaUI

@Suite @MainActor struct ActionsToolsUITests {
    @Test func settingsCRUDImportReviewAndScopedPreview() throws {
        let recorder = SettingsRecorder()
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            recorder.tearDown()
            try? FileManager.default.removeItem(at: folder)
        }
        let store = CustomActionStore(fileURL: folder.appending(path: "actions.json"))
        var reviewedImport = ""
        let alerts = AlertPresenter { alert, _, done in
            reviewedImport = alert.informativeText
            done(.alertFirstButtonReturn)
        }
        let pane = CustomActionsSettingsPane(environment: recorder.environment, store: store, alerts: alerts)
        #expect(pane.actions.isEmpty)
        pane.add()
        pane.duplicate()
        pane.didAppear()
        #expect(pane.actions.count == 2)
        pane.deleteSelected()
        var action = try #require(store.load().first)
        action.scope = .branch
        action.arguments = ["x y", "$BRANCH"]
        let presenter = CustomActionsPresenter()
        let preview = try presenter.preview(action)
        #expect(preview.contains("Directory: /Projects/Example"))
        #expect(preview.contains("[1] \"x y\"") && preview.contains("feature/review"))
        #expect(presenter.summary(action) == action.executable)
        #expect(presenter.scopeBadge(action) == action.scope.localizedTitle)
        action.confirmsBeforeRun = false
        let data = try presenter.export([action], store: store)
        pane.importData(data)
        #expect(reviewedImport.contains(action.name))
        #expect(pane.actions.first?.confirmsBeforeRun == true)
    }

    @Test func outputCompletionCloseCancellationAndSilentFailure() async throws {
        UITestSupport.bootstrap()
        let root = FileManager.default.temporaryDirectory
        let context = CustomActionContext(repositoryRoot: root, filePath: "file with spaces")
        let action = CustomAction(name: "Echo", scope: .file, executable: "/bin/echo", arguments: ["$FILE"])
        let controller = CustomActionOutputWindowController(action: action)
        controller.start(context: context)
        #expect(controller.state.isRunning)
        #expect(await eventually(timeout: .seconds(5)) { controller.state.output != nil })
        #expect(controller.state.output?.stdout == root.appending(path: "file with spaces").path + "\n")
        controller.close()

        let slow = CustomActionOutputWindowController(
            action: CustomAction(name: "Wait", executable: "/bin/sleep", arguments: ["30"]))
        slow.start(context: context)
        slow.close()
        #expect(!slow.state.isRunning && slow.state.errorMessage != nil)

        // A silent action that fails must still surface its sheet on the parent window.
        let parent = NSWindow()
        var failing = CustomAction(name: "Fail", executable: "/usr/bin/false")
        failing.showsOutput = false
        failing.confirmsBeforeRun = false
        let silentFailure = CustomActionOutputWindowController(action: failing)
        silentFailure.present(context: context, on: parent)
        #expect(await eventually(timeout: .seconds(5)) { silentFailure.state.output?.succeeded == false })
        #expect(silentFailure.window?.sheetParent === parent)
        silentFailure.close()
    }

    @Test func confirmationControlsSilentActions() async throws {
        UITestSupport.bootstrap()
        let parent = NSWindow()
        let context = CustomActionContext(repositoryRoot: FileManager.default.temporaryDirectory)
        var action = CustomAction(name: "Silent", executable: "/bin/echo", arguments: ["literal argument"])
        action.showsOutput = false
        let controller = CustomActionOutputWindowController(action: action)
        let decline = AlertPresenter { _, _, done in done(.alertSecondButtonReturn) }
        controller.present(context: context, on: parent, alerts: decline)
        #expect(controller.state == .idle)
        let accept = AlertPresenter { alert, _, done in
            #expect(alert.informativeText.contains("Directory: "))
            #expect(alert.informativeText.contains("literal argument"))
            done(.alertFirstButtonReturn)
        }
        controller.present(context: context, on: parent, alerts: accept)
        #expect(await eventually(timeout: .seconds(5)) { controller.state.output != nil })
        #expect(controller.state.output?.succeeded == true)
        #expect(controller.window?.isVisible == false)
        controller.close()
    }

    @Test func tokenControlsScopePillsAndDeferredCommit() throws {
        UITestSupport.bootstrap()
        let editor = CustomActionEditor()
        var draftUpdates = 0
        var commits: [CustomAction] = []
        let initial = CustomAction(
            name: "Example", scope: .file, executable: "tool", arguments: ["first", "two words"])
        editor.onDraftChange = { _ in draftUpdates += 1 }
        editor.onCommit = { commits.append($0) }
        editor.select(initial)
        let pillTitles = SharedFixtures.descendants(editor.tokens, of: ActionButton.self).map(\.title)
        #expect(pillTitles.contains("$FILE") && !pillTitles.contains("$SHA"))

        let down = try #require(
            editor.tokens.rows.first?.accessories.arrangedSubviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip == String(localized: "Move down") })
        down.performClick(nil)
        #expect(commits.last?.arguments == ["two words", "first"])
        let pill = try #require(
            SharedFixtures.descendants(editor.tokens, of: ActionButton.self).first { $0.title == "$FILE" })
        pill.performClick(nil)
        #expect(commits.last?.arguments == ["two words", "first$FILE"])
        let add = try #require(
            SharedFixtures.descendants(editor.tokens, of: ActionButton.self).first {
                $0.title == String(localized: "Add argument")
            })
        add.performClick(nil)
        let commitsBeforeTyping = commits.count
        let field = try #require(editor.tokens.rows[2].accessories.arrangedSubviews.first as? ActionEditorField)
        field.stringValue = "one literal argument"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(draftUpdates > 0)
        #expect(commits.count == commitsBeforeTyping)
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(commits.count == commitsBeforeTyping + 1)
        #expect(commits.last?.arguments.last == "one literal argument")
    }

    @Test func patchReviewBlocksCloseDuringApplyAndShowsRecheck() async throws {
        UITestSupport.bootstrap()
        let url = FileManager.default.temporaryDirectory.appending(path: "example.patch")
        let stat = PatchFileStat(path: "file", additions: 2, deletions: 1, isBinary: false)
        let preview = PatchPreview(
            patchURL: url, files: [stat], canApplyCleanly: true, canApplyWithThreeWay: false,
            diagnostic: nil, contentDigest: "fixture")
        let presenter = PatchApplyPresenter()
        #expect(presenter.canApply(.ready(preview), threeWay: false))
        #expect(!presenter.canApply(.ready(preview), threeWay: true))
        #expect(presenter.showsRecheck(.failed("changed"), threeWay: false))
        #expect(!presenter.banner(.checking, threeWay: false).isEmpty)

        let gate = ApplyGate()
        let sheet = PatchApplySheetController(
            patchURL: url, check: { _, _ in preview },
            apply: { _, options in await gate.enter(options) })
        sheet.refreshPreview()
        #expect(await eventually(timeout: .seconds(5)) { sheet.state == .ready(preview) })
        sheet.applyReviewed()
        #expect(await eventually(timeout: .seconds(5)) { gate.entered })
        // Closing while applying must not cancel or close the sheet.
        #expect(sheet.windowShouldClose(try #require(sheet.window)) == false)
        sheet.close()
        #expect(sheet.state == .applying(preview))
        await gate.release()
        #expect(await eventually(timeout: .seconds(5)) { sheet.state == .applied(preview) })
        #expect(await gate.options == [PatchApplyOptions()])
        sheet.close()
    }

    @Test func patchExportAndClipboard() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = PatchExportHelper(destination: { folder.appending(path: $0) })
        let payload = Data("diff\n".utf8)
        let result = await helper.export(.staged) { _ in payload }
        guard case .saved(let url, _) = result else {
            Issue.record("Expected a saved patch")
            return
        }
        #expect(url.lastPathComponent == "staged.patch")
        #expect(try Data(contentsOf: url) == payload)
        #expect(helper.filename(for: .commitRange(from: "a", to: "b")) == "a..b.patch")
        let cancelled = PatchExportHelper(destination: { _ in nil })
        #expect(await cancelled.export(.workingTree) { _ in throw PatchError.emptyPatch } == .cancelled)
        guard case .failed = await helper.export(.workingTree, read: { _ in throw PatchError.emptyPatch }) else {
            Issue.record("Expected export error")
            return
        }
        var clipboard: [URL] = []
        let links = PermalinkHelper(sink: {
            clipboard.append($0)
            return true
        })
        _ = links.copyCommit(remote: "git@github.com:a/b", sha: "abc")
        _ = links.copyFile(remote: "git@github.com:a/b", ref: "abc", path: "file", lines: 4...5)
        #expect(
            clipboard.map(\.absoluteString) == [
                "https://github.com/a/b/commit/abc", "https://github.com/a/b/blob/abc/file#L4-L5",
            ])
        guard case .unavailable = links.copyCommit(remote: "/tmp/repo", sha: "a") else {
            Issue.record("Expected an unavailable link")
            return
        }
        #expect(clipboard.count == 2)
    }

    @Test func customToolControlsPersistLiteralTokens() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let view = ExternalToolsSettingsView(defaults: recorder.defaults)
        let popup = try #require(SharedFixtures.descendants(view, of: ActionPopUpButton.self).first)
        #expect(popup.select(value: ExternalToolPreset.custom.rawValue))
        popup.onChange(popup)
        let fields = SharedFixtures.descendants(view, of: ActionEditorField.self)
        #expect(fields.count == 2)
        let path = try #require(fields.first)
        path.stringValue = "/path/to/tool"
        path.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let args = try #require(fields.last)
        args.stringValue = #"["--file=$LEFT", "", "$RIGHT"]"#
        args.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let saved = ExternalToolConfig.load(from: recorder.defaults)
        #expect(
            saved.diffTool
                == ExternalToolSelection(
                    preset: .custom, customExecutable: "/path/to/tool",
                    customArguments: ["--file=$LEFT", "", "$RIGHT"]))
        #expect(saved.mergeTool == ExternalToolSelection())
    }

    @Test func toolSettingsLifecycleAndPresentation() async throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let detector = ExternalToolDetector(fileExists: { $0 == "/usr/local/bin/code" }, applicationURL: { _ in nil })
        let pane = ExternalToolsSettingsPane(environment: recorder.environment, detector: detector)
        pane.didAppear()
        #expect(await eventually(timeout: .seconds(5)) { !pane.tools.detections.isEmpty })
        let detection = pane.tools.detections[.vsCode]
        let presenter = ExternalToolsPresenter()
        let selection = ExternalToolSelection(preset: .vsCode)
        #expect(presenter.executable(selection, detection: detection) == "/usr/local/bin/code")
        #expect(presenter.arguments(selection, kind: .diff).contains("$LEFT"))
        #expect(presenter.validation(selection, kind: .merge, detection: detection) == nil)
        #expect(!presenter.installedBadge(detection).isEmpty)
        #expect(presenter.presets(for: .merge).contains(.custom))
        #expect(presenter.banner(.failed("reason")) == "reason")
        pane.didDisappear()
        let view = ExternalToolsSettingsView(defaults: recorder.defaults, detector: detector)
        view.didAppear()
        view.didDisappear()
        #expect(view.detections.isEmpty)
    }
}

private actor ApplyGate {
    private let enteredFlag = OSAllocatedUnfairLock(initialState: false)
    nonisolated var entered: Bool { enteredFlag.withLock { $0 } }
    var options: [PatchApplyOptions] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func enter(_ option: PatchApplyOptions) async {
        enteredFlag.withLock { $0 = true }
        options.append(option)
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
