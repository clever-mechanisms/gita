import AppKit
import GitaCore

/// Something up a view's responder chain that opens the live Vercel Visual Preview Diff window.
@MainActor
protocol VisualPreviewOpening: AnyObject {
    func openVisualPreviewDiff(for deployment: DeploymentDetail)
}

extension NSResponder {
    var visualPreviewOpener: (any VisualPreviewOpening)? {
        sequence(first: self, next: \.nextResponder).lazy.compactMap { $0 as? any VisualPreviewOpening }.first
    }
}

extension PartsButton {
    static func visualPreviewDiff(_ deployment: DeploymentDetail, from source: NSView) -> PartsButton {
        let title = String(localized: "Visual Diff")
        let button = Self.quiet(title, symbol: "rectangle.split.2x1") { [weak source] in
            source?.visualPreviewOpener?.openVisualPreviewDiff(for: deployment)
        }
        button.toolTip = String(localized: "Compare production and preview visually")
        button.setAccessibilityLabel(title)
        return button
    }
}

extension RepositoryViewController: VisualPreviewOpening {
    func openVisualPreviewDiff(for deployment: DeploymentDetail) {
        let vercelContext = model.reports.first(where: { $0.provider == .vercel })?.vercel
        if let pair = SmartDiffFacade.shared.resolvePreviewPair(
            vercelContext: vercelContext, previewDeployment: deployment)
        {
            SmartDiffFacade.shared.openVisualPreviewDiff(
                productionURL: pair.productionURL, previewURL: pair.previewURL, title: pair.title)
        } else if let previewURL = Deck.safeWebURL(deployment.previewURL) {
            SmartDiffFacade.shared.openVisualPreviewDiff(
                productionURL: previewURL, previewURL: previewURL,
                title: deployment.projectName)
        }
    }
}
