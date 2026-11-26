import Foundation
import GitaCore

@MainActor
public final class VisualPreviewDiffPresenter {
    public private(set) var state = VisualPreviewDiffState.idle
    public private(set) var mode = VisualPreviewDiffMode.sideBySide
    public private(set) var viewport = VisualPreviewViewport.responsive
    public private(set) var route: String
    public private(set) var curtainPosition: CGFloat = 0.5
    public private(set) var onionOpacity: CGFloat = 0.5
    public let productionURL: URL?
    public let previewURL: URL?
    public var onCurtainChange: (() -> Void)?
    public var onChange: (() -> Void)?

    public init(productionURL: URL, previewURL: URL, initialRoute: String = "/") {
        self.productionURL = VisualPreviewURLValidator.validatedHTTPSURL(productionURL)
        self.previewURL = VisualPreviewURLValidator.validatedHTTPSURL(previewURL)
        route = VisualPreviewURLValidator.normalizedRoute(initialRoute)
    }

    public var resolvedURLs: (production: URL, preview: URL)? {
        guard let productionURL, let previewURL,
            let production = VisualPreviewURLValidator.resolvedURL(base: productionURL, route: route),
            let preview = VisualPreviewURLValidator.resolvedURL(base: previewURL, route: route)
        else { return nil }
        return (production, preview)
    }

    public func setMode(_ mode: VisualPreviewDiffMode) {
        self.mode = mode
        onChange?()
    }
    public func setViewport(_ viewport: VisualPreviewViewport) {
        self.viewport = viewport
        onChange?()
    }
    public func setRoute(_ route: String) {
        self.route = VisualPreviewURLValidator.normalizedRoute(route)
        onChange?()
    }

    public func setCurtainPosition(_ value: CGFloat) {
        curtainPosition = value.isNaN ? 0.5 : min(0.95, max(0.05, value))
        onCurtainChange?()
    }

    public func setOnionOpacity(_ value: CGFloat) {
        onionOpacity = value.isNaN ? 0.5 : min(1, max(0, value))
        onChange?()
    }

    public func beginLoading() {
        guard resolvedURLs != nil else {
            fail(String(localized: "Both deployments need a valid HTTPS address."))
            return
        }
        state = .loading(productionLoaded: false, previewLoaded: false)
        onChange?()
    }

    func started(production: Bool) {
        switch state {
        case .ready: state = .loading(productionLoaded: !production, previewLoaded: production)
        case .loading(let live, let preview):
            state = .loading(productionLoaded: live && !production, previewLoaded: preview && production)
        default: return
        }
        onChange?()
    }

    public func finished(production: Bool) {
        guard case .loading(let live, let preview) = state else { return }
        let both = (live || production) && (preview || !production)
        state = both ? .ready : .loading(productionLoaded: live || production, previewLoaded: preview || !production)
        onChange?()
    }

    public func fail(_ reason: String) {
        state = .failed(reason)
        onChange?()
    }

    public var statusCaption: String {
        switch state {
        case .idle: String(localized: "Waiting for deployments")
        case .loading(true, _): String(localized: "Loading preview…")
        case .loading(_, true): String(localized: "Loading production…")
        case .loading: String(localized: "Loading deployments…")
        case .ready: String(localized: "Both deployments loaded")
        case .failed(let reason): reason
        }
    }
}
