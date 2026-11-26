import AppKit
import GitaCore

@MainActor public enum SpeculativeGitFacade {
    public static func rebasePreview(
        service: SpeculativeGitService, onto: String, steps: [GitRebaseStep]
    )
        -> SpeculativePreviewPanelController
    {
        panel(service) { .rebase(try await service.simulateRebase(onto: onto, steps: steps)) }
    }

    public static func pairwisePreview(
        service: SpeculativeGitService, ours: String, theirs: String
    )
        -> SpeculativePreviewPanelController
    {
        panel(service) { .pairwiseMerge(try await service.checkPairwiseMerge(ours: ours, theirs: theirs)) }
    }

    public static func preFlightPreview(
        service: SpeculativeGitService, kind: PreFlightKind, target: String,
        onto: String = "HEAD"
    ) -> SpeculativePreviewPanelController {
        panel(service) {
            switch kind {
            case .cherryPick: .preFlight(try await service.checkCherryPick(commit: target, onto: onto))
            case .stash: .preFlight(try await service.checkStashApply(stashRef: target, onto: onto))
            }
        }
    }

    private static func panel(
        _ service: SpeculativeGitService, request: @escaping SpeculativePreviewPresenter.Simulation
    )
        -> SpeculativePreviewPanelController
    {
        let presenter = SpeculativePreviewPresenter(service: service)
        presenter.simulate(request)
        return SpeculativePreviewPanelController(presenter: presenter)
    }

    public static func presentPreview(
        _ panel: SpeculativePreviewPanelController, on parent: NSWindow, proceedTitle: String? = nil,
        onProceed: (@MainActor () -> Void)? = nil
    ) {
        let sheet = SheetChrome(
            title: String(localized: "Conflict Preview"),
            layout: .init(width: 760, spacing: 8), identifier: "speculative.sheet")
        let controller = PreviewSheetController()
        if let content = sheet.window.contentView {
            controller.view = content
            sheet.window.contentViewController = controller
        }
        controller.addChild(panel)
        sheet.add(panel.view, height: 380)
        sheet.setFlexibleRow(panel.view, preferred: 380, minimum: 160)
        var footer = [SheetChrome.spacer()]
        let primary: NSButton
        if onProceed != nil {
            let cancel = SheetChrome.button(String(localized: "Cancel"), id: "speculative.sheet.cancel")
            cancel.keyEquivalent = "\u{1b}"
            cancel.target = controller
            cancel.action = #selector(NSResponder.cancelOperation(_:))
            primary = SheetChrome.button(
                proceedTitle ?? String(localized: "Continue"), id: "speculative.sheet.proceed")
            footer.append(cancel)
        } else {
            primary = SheetChrome.button(String(localized: "Done"), id: "speculative.sheet.done")
        }
        primary.target = controller
        primary.action = #selector(PreviewSheetController.accept)
        footer.append(primary)
        sheet.complete(footer: footer)
        panel.onStatusChange = { [weak sheet] status in sheet?.show(status) }
        panel.isHostedInSheet = true
        parent.beginSheet(sheet.window) { [sheet, panel] response in
            panel.onStatusChange = nil
            panel.presenter.cancel()
            sheet.window.orderOut(nil)
            panel.removeFromParent()
            panel.isHostedInSheet = false
            if response == .OK { onProceed?() }
        }
        sheet.window.defaultButtonCell = primary.cell as? NSButtonCell
        primary.keyEquivalent = "\r"
        sheet.fit()
    }

    public static func makeBadgeView() -> ConflictRiskBadgeView { ConflictRiskBadgeView() }

    /// Keep the returned controller to preserve the editable plan and selection across window closures.
    public static func makeCommitBucketsWindow(
        gitService: GitService, agent: AgentTool? = nil,
        onCommitted: ((CommitBucketExecutionResult) -> Void)? = nil
    ) -> CommitBucketsWindowController {
        let controller = CommitBucketsWindowController(gitService: gitService, agent: agent)
        controller.presenter.onCommitted = onCommitted
        return controller
    }
}

private final class PreviewSheetController: NSViewController {
    @objc func accept() {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window, returnCode: .OK)
    }

    override func cancelOperation(_: Any?) {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window, returnCode: .cancel)
    }
}
