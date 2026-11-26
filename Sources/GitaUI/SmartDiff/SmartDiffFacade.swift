import AppKit
import GitaCore

@MainActor
public final class SmartDiffFacade {
    public static let shared = SmartDiffFacade()
    private struct WindowKey: Hashable {
        let production: URL
        let preview: URL
    }
    private var windows: [WindowKey: VisualPreviewDiffWindowController] = [:]

    public init() {}

    public func zoomMetrics(for scale: CGFloat) -> HistoryZoomMetrics { HistoryZoomMetrics.resolve(zoomScale: scale) }

    public func makeVelocitySparklineView(
        commits: [GitCommit] = [], fileChurnByCommit: [String: Int] = [:],
        onSelectBucket: ((VelocityBucket) -> Void)? = nil
    ) -> VelocitySparklineOverlayView {
        let view = VelocitySparklineOverlayView()
        view.onSelectBucket = onSelectBucket
        updateVelocitySparkline(view, commits: commits, fileChurnByCommit: fileChurnByCommit)
        return view
    }

    public func updateVelocitySparkline(
        _ view: VelocitySparklineOverlayView, commits: [GitCommit], fileChurnByCommit: [String: Int] = [:]
    ) {
        view.update(HistoryVelocityAggregator.aggregate(commits: commits, fileChurnByCommit: fileChurnByCommit))
    }

    public func orderFiles(_ files: [FileChange], mode: FileOrderMode = .narrative) -> [NarrativeFileGroup] {
        NarrativeFileOrderer.group(files, mode: mode)
    }

    public func makeNarrativeOrderModeControl(
        mode: FileOrderMode = .narrative, onChange: ((FileOrderMode) -> Void)? = nil
    ) -> NarrativeOrderModeControl {
        let control = NarrativeOrderModeControl()
        control.setMode(mode)
        control.onChange = onChange
        return control
    }

    public func makeNarrativeHeaderView(
        group: NarrativeFileGroup, presenter: NarrativeOrderPresenter, onToggle: (() -> Void)? = nil
    ) -> NarrativeOrderHeaderView {
        NarrativeOrderHeaderView(group: group, presenter: presenter, onToggle: onToggle)
    }

    public func makeSmartDiffViewController(onJumpToFileLine: ((String, Int) -> Void)? = nil) -> SmartDiffViewController
    {
        let controller = SmartDiffViewController()
        controller.onJumpToFileLine = onJumpToFileLine
        return controller
    }

    public func resolvePreviewPair(
        vercelContext: VercelContext?, previewDeployment: DeploymentDetail?
    ) -> VisualPreviewPair? {
        VisualPreviewURLValidator.resolvePair(vercelContext: vercelContext, previewDeployment: previewDeployment)
    }

    @discardableResult
    public func openVisualPreviewDiff(
        productionURL: URL, previewURL: URL, title: String? = nil, initialRoute: String = "/"
    ) -> VisualPreviewDiffWindowController {
        let key = WindowKey(production: productionURL, preview: previewURL)
        if let existing = windows[key] {
            existing.showWindow(nil)
            return existing
        }
        let pair = VisualPreviewPair(
            productionURL: productionURL, previewURL: previewURL,
            title: title ?? String(localized: "Production and preview"))
        let controller = VisualPreviewDiffWindowController(pair: pair, initialRoute: initialRoute)
        controller.onClose = { [weak self] in self?.windows.removeValue(forKey: key) }
        windows[key] = controller
        controller.showWindow(nil)
        return controller
    }
}
