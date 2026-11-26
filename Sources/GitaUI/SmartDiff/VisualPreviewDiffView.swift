import AppKit
import GitaCore
import WebKit

@MainActor
final class VisualPreviewDiffView: NSView, WKNavigationDelegate {
    let presenter: VisualPreviewDiffPresenter
    private let canvas: VisualPreviewCanvas
    private let toolbar: VisualPreviewToolbar
    var productionWebView: WKWebView { canvas.productionWebView }
    var previewWebView: WKWebView { canvas.previewWebView }
    private let sync: VisualPreviewScrollSync
    private var pending: [ObjectIdentifier: WKNavigation] = [:]
    private let superseded = NSHashTable<WKNavigation>.weakObjects()
    private let caption = Deck.caption("")
    private let spinner = NSProgressIndicator()
    private var delay: Task<Void, Never>?
    private var renderedState: VisualPreviewDiffState?
    private let stateMessage = Deck.wrapping("", color: Theme.secondaryText)
    private lazy var stateButton = SmartDiffControls.button("", id: "preview.load") { [weak self] in self?.reload() }
    private lazy var stateView = Deck.vstack([stateMessage, stateButton])
    private lazy var status = Deck.hstack([spinner, caption, Deck.spacer()])

    init(presenter: VisualPreviewDiffPresenter) {
        self.presenter = presenter
        canvas = VisualPreviewCanvas(presenter)
        toolbar = VisualPreviewToolbar(presenter)
        sync = VisualPreviewScrollSync(production: canvas.productionWebView, preview: canvas.previewWebView)
        super.init(frame: .zero)
        setup()
        presenter.onChange = { [weak self] in self?.refresh() }
        presenter.onCurtainChange = { [weak canvas] in canvas?.updateCurtain() }
        toolbar.onNavigate = { [weak self] in self?.reload() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(presenter:)") }

    private func setup() {
        let background = ThemedBackgroundView()
        Deck.pin(background, in: self)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let slot = NSView()
        Deck.pin(canvas, in: slot)
        slot.addSubview(stateView)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.alignment = .centerX
        stateMessage.alignment = .center
        NSLayoutConstraint.activate([
            stateView.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            stateView.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            stateView.widthAnchor.constraint(lessThanOrEqualTo: slot.widthAnchor, constant: -16),
        ])
        status.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let stack = Deck.vstack([toolbar, slot, status], spacing: 0)
        Deck.pin(stack, in: background)
        for child in [toolbar as NSView, slot, status] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        productionWebView.navigationDelegate = self
        previewWebView.navigationDelegate = self
        smartDiffAccessibility(String(localized: "Live deployment comparison"), "preview.view")
    }

    private func refresh() {
        toolbar.refresh()
        canvas.needsLayout = true
        let state = presenter.state
        guard renderedState != state else { return }
        let previous = renderedState
        renderedState = state
        caption.stringValue = presenter.statusCaption
        caption.toolTip = caption.stringValue
        updateStateView(state)
        if case .loading = state {
            if case .loading = previous { return }
            delay = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self?.spinner.startAnimation(nil)
            }
        } else {
            delay?.cancel()
            spinner.stopAnimation(nil)
        }
    }

    private func updateStateView(_ state: VisualPreviewDiffState) {
        let title: String
        switch state {
        case .idle:
            stateMessage.stringValue = String(localized: "Compare production and preview deployments")
            stateMessage.font = Theme.caption
            stateMessage.textColor = Theme.secondaryText
            title = String(localized: "Load Comparison")
        case .failed(let reason):
            stateMessage.stringValue = reason
            stateMessage.font = Theme.body
            stateMessage.textColor = Theme.failure
            title = String(localized: "Retry")
        case .loading, .ready:
            stateView.isHidden = true
            canvas.isHidden = false
            status.isHidden = false
            return
        }
        let moveFocus = (window?.firstResponder as? NSView)?.isDescendant(of: canvas) == true
        stateButton.parts = SmartDiffControls.parts(title, symbol: nil)
        stateButton.setAccessibilityLabel(title)
        stateButton.toolTip = title
        stateView.isHidden = false
        canvas.isHidden = true
        status.isHidden = true
        if moveFocus { window?.makeFirstResponder(stateButton) }
    }

    func reload() {
        for navigation in pending.values { superseded.add(navigation) }
        pending.removeAll()
        productionWebView.isHidden = true
        previewWebView.isHidden = true
        presenter.beginLoading()
        guard let urls = presenter.resolvedURLs else { return }
        navigate(productionWebView, to: urls.production)
        navigate(previewWebView, to: urls.preview)
    }

    private func navigate(_ web: WKWebView, to url: URL) {
        web.stopLoading()
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        guard let navigation = web.load(request) else {
            presenter.fail(String(localized: "The deployment couldn’t be loaded."))
            return
        }
        pending[ObjectIdentifier(web)] = navigation
    }

    func webView(
        _: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let target = navigationAction.targetFrame.map { $0.isMainFrame ? NavigationTarget.mainFrame : .subframe }
        let allowed = allowsNavigation(
            to: navigationAction.request.url, target: target ?? .newWindow,
            linkActivated: navigationAction.navigationType == .linkActivated)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(
        _: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let allowed = allowsNavigation(
            to: navigationResponse.response.url, target: navigationResponse.isForMainFrame ? .mainFrame : .subframe)
        decisionHandler(allowed ? .allow : .cancel)
    }

    enum NavigationTarget { case mainFrame, subframe, newWindow }

    func allowsNavigation(to url: URL?, target: NavigationTarget, linkActivated: Bool = false) -> Bool {
        if VisualPreviewURLValidator.validatedHTTPSURL(url) != nil { return true }
        switch target {
        case .subframe:
            return ["about", "data", "blob"].contains(url?.scheme?.lowercased() ?? "")
        case .mainFrame where !linkActivated:
            presenter.fail(String(localized: "This comparison requires an HTTPS address."))
        default: break
        }
        return false
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        guard let navigation, !superseded.contains(navigation) else { return }
        pending[ObjectIdentifier(webView)] = navigation
        presenter.started(production: webView === productionWebView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        guard let navigation, pending[ObjectIdentifier(webView)] === navigation else { return }
        webView.isHidden = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard let navigation, pending[ObjectIdentifier(webView)] === navigation else { return }
        pending.removeValue(forKey: ObjectIdentifier(webView))
        presenter.finished(production: webView === productionWebView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        failed(webView, navigation, error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        failed(webView, navigation, error)
    }

    private func failed(_ web: WKWebView, _ navigation: WKNavigation?, _ error: any Error) {
        guard let navigation, pending[ObjectIdentifier(web)] === navigation else { return }
        pending.removeValue(forKey: ObjectIdentifier(web))
        if case .failed = presenter.state { return }
        let failure = error as NSError
        if failure.code == NSURLErrorCancelled || (failure.domain == "WebKitErrorDomain" && failure.code == 102) {
            guard case .loading = presenter.state else { return }
            if web.isHidden {
                presenter.fail(String(localized: "The deployment couldn’t be shown."))
            } else {
                presenter.finished(production: web === productionWebView)
            }
            return
        }
        let reason = error.localizedDescription
        presenter.fail(String(localized: "Couldn’t load deployment. \(reason)"))
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        presenter.fail(String(localized: "The deployment page stopped responding."))
    }

    func tearDown() {
        delay?.cancel()
        spinner.stopAnimation(nil)
        presenter.onCurtainChange = nil
        presenter.onChange = nil
        sync.tearDown()
        pending.removeAll()
        for web in [productionWebView, previewWebView] {
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.stopLoading()
            web.removeFromSuperview()
        }
    }

    deinit { delay?.cancel() }
}
