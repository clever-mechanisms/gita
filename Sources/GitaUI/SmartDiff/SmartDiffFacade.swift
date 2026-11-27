import AppKit
import GitaCore

@MainActor
final class SmartDiffFacade {
    static let shared = SmartDiffFacade()

    init() {}

    func zoomMetrics(for scale: CGFloat) -> HistoryZoomMetrics { HistoryZoomMetrics.resolve(zoomScale: scale) }

    func makeVelocitySparklineView(
        commits: [GitCommit] = [], fileChurnByCommit: [String: Int] = [:],
        onSelectBucket: ((VelocityBucket) -> Void)? = nil
    ) -> VelocitySparklineOverlayView {
        let view = VelocitySparklineOverlayView()
        view.onSelectBucket = onSelectBucket
        updateVelocitySparkline(view, commits: commits, fileChurnByCommit: fileChurnByCommit)
        return view
    }

    func updateVelocitySparkline(
        _ view: VelocitySparklineOverlayView, commits: [GitCommit], fileChurnByCommit: [String: Int] = [:]
    ) {
        view.update(HistoryVelocityAggregator.aggregate(commits: commits, fileChurnByCommit: fileChurnByCommit))
    }

    func orderFiles(_ files: [FileChange], mode: FileOrderMode = .narrative) -> [NarrativeFileGroup] {
        NarrativeFileOrderer.group(files, mode: mode)
    }

    func makeNarrativeOrderModeControl(
        mode: FileOrderMode = .narrative, onChange: ((FileOrderMode) -> Void)? = nil
    ) -> NarrativeOrderModeControl {
        let control = NarrativeOrderModeControl()
        control.setMode(mode)
        control.onChange = onChange
        return control
    }

    func makeNarrativeHeaderView(
        group: NarrativeFileGroup, presenter: NarrativeOrderPresenter, onToggle: (() -> Void)? = nil
    ) -> NarrativeOrderHeaderView {
        NarrativeOrderHeaderView(group: group, presenter: presenter, onToggle: onToggle)
    }

    func makeSmartDiffViewController(onJumpToFileLine: ((String, Int) -> Void)? = nil) -> SmartDiffViewController {
        let controller = SmartDiffViewController()
        controller.onJumpToFileLine = onJumpToFileLine
        return controller
    }

    func resolvePreviewPair(
        vercelContext: VercelContext?, previewDeployment: DeploymentDetail?
    ) -> VisualPreviewPair? {
        VisualPreviewURLValidator.resolvePair(vercelContext: vercelContext, previewDeployment: previewDeployment)
    }
}
