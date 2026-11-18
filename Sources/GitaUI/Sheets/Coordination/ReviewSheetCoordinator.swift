import AppKit
import GitaCore

/// A review sheet controller's own close and termination API.
@MainActor
protocol CoordinatedSheet: NSWindowController {
    var isApplying: Bool { get }
    func requestApplicationTermination(_ reply: @escaping (Bool) -> Void)
    func dismissForApprovedTermination()
}

extension ReferenceReviewController: CoordinatedSheet {}
extension ResetReviewController: CoordinatedSheet {}
extension InteractiveRebaseController: CoordinatedSheet {}
extension RemoteManagementController: CoordinatedSheet {}

/// One review sheet as the coordinator drives it, built from the sheet controller's own API.
@MainActor
struct ReviewSheetHandle {
    var controller: NSWindowController
    /// The sheet is writing to the repository and cannot close now.
    var isApplying: () -> Bool
    /// Asks the sheet to close (it may ask about unsaved edits first).
    var requestClose: () -> Void
    var requestTermination: (@escaping (Bool) -> Void) -> Void
    var dismissForTermination: () -> Void

    /// A sheet that closes with its repository; `close()` asks it to close.
    init(_ sheet: some CoordinatedSheet) {
        controller = sheet
        isApplying = { [weak sheet] in sheet?.isApplying == true }
        requestClose = { [weak sheet] in sheet?.close() }
        requestTermination = { [weak sheet] reply in
            guard let sheet else { return reply(true) }
            sheet.requestApplicationTermination(reply)
        }
        dismissForTermination = { [weak sheet] in sheet?.dismissForApprovedTermination() }
    }
}

/// The window's review sheet (reference, reset, interactive rebase, remotes): a window shows at most one
/// attached sheet, so one entry with the service it reviews is enough, and every close rule lives here.
@MainActor
final class ReviewSheetCoordinator {
    private struct Active {
        var handle: ReviewSheetHandle
        var service: GitService?
    }
    private var active: Active?

    var hasSheet: Bool { active != nil }

    /// Presents `handle`'s window as a sheet on `window` for `service`.
    func present(_ handle: ReviewSheetHandle, service: GitService?, on window: NSWindow) {
        guard let sheet = handle.controller.window else { return }
        active = Active(handle: handle, service: service)
        let controller = handle.controller
        window.beginSheet(sheet) { [weak self, weak controller] _ in
            guard let self, let controller, self.active?.handle.controller === controller else { return }
            self.active = nil
        }
    }

    /// The tab's model now reads `service`: a sheet for another repository closes unless it is applying.
    func repositoryChanged(to service: GitService?) {
        guard let active, active.service !== service else { return }
        closeUnlessApplying(active)
    }

    /// The tab closes.
    func detach() {
        guard let active else { return }
        closeUnlessApplying(active)
    }

    private func closeUnlessApplying(_ entry: Active) {
        // The entry goes when the sheet has closed (it may first ask about unsaved edits).
        guard !entry.handle.isApplying() else { return }
        entry.handle.requestClose()
    }

    func requestApplicationTermination(_ reply: @escaping (Bool) -> Void) {
        guard let active else {
            reply(true)
            return
        }
        active.handle.requestTermination(reply)
    }

    func dismissForTermination() {
        active?.handle.dismissForTermination()
        active = nil
    }

    /// ⌘W and Escape-like closes: true when there was a sheet to ask.
    func closeSheet() -> Bool {
        guard let active else { return false }
        active.handle.requestClose()
        return true
    }
}
