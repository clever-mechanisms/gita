import AppKit
import WebKit

/// The built-in terminal: xterm.js in a web view, loaded from the app's `Terminal` resources, showing one
/// `TerminalSession`. The page never loads anything from outside the bundle. Its colours follow the app's theme and
/// Settings ▸ General ▸ Terminal colours, and change with them.
@MainActor
final class TerminalView: NSView, WKNavigationDelegate {
    /// The page and xterm.js inside the app bundle.
    static var bundledPage: URL? { Bundle.main.resourceURL?.appendingPathComponent("Terminal", isDirectory: true) }

    let session: TerminalSession
    let webView: WKWebView
    /// The look the page has now.
    private(set) var look: TerminalAppearance
    private let defaults: UserDefaults
    private let observations = NotificationObservations()
    /// Focus was asked for before the page was up; it is given once it is.
    private var wantsFocus = false

    /// Shows `session`; `page` is the folder holding `index.html` (nothing loads without one).
    init(
        session: TerminalSession, page: URL? = bundledPage,
        appearance: NSAppearance = NSApplication.shared.effectiveAppearance, defaults: UserDefaults = Preference.store
    ) {
        self.session = session
        self.defaults = defaults
        look = TerminalAppearance.current(appearance: appearance, defaults: defaults)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let messages = TerminalMessageHandler()
        configuration.userContentController.add(messages, name: "terminal")
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: "window.gitaTerminal = \(look.json);", injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        paintBackground()
        // The theme, Terminal colours or a shortcut changed in Settings.
        observations.observe(.gitaPreferenceChanged) { [weak self] in self?.restyle() }
        // Hidden until its page has drawn: a web view is white before then, the terminal's background shows instead.
        webView.isHidden = true
        webView.navigationDelegate = self
        webView.setAccessibilityLabel(String(localized: "Terminal"))
        Deck.pin(webView, in: self)
        messages.onMessage = { [weak self] body in self?.received(body) }
        session.evaluate = { [weak webView] script in webView?.evaluateJavaScript(script) }
        if let page { webView.loadFileURL(page.appendingPathComponent("index.html"), allowingReadAccessTo: page) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("TerminalView is built in code") }

    /// Puts the keyboard in the terminal (once its page is up).
    func focus() {
        guard !webView.isHidden else {
            wantsFocus = true
            return
        }
        window?.makeFirstResponder(webView)
        session.evaluate?("gita.focus()")
    }

    func received(_ body: Any) {
        guard let message = TerminalMessage(body) else { return }
        // A page that just loaded started with the look it was built with: a change made while it loaded (or before
        // it loaded again) reaches it now.
        if case .ready = message { session.evaluate?("gita.configure(\(look.json))") }
        session.handle(message)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    /// Sends the page the look the settings and appearance call for now, when it changed.
    func restyle() {
        let current = TerminalAppearance.current(appearance: effectiveAppearance, defaults: defaults)
        guard current != look else { return }
        look = current
        paintBackground()
        session.evaluate?("gita.configure(\(look.json))")
    }

    /// The view behind the page in the terminal's background, so nothing flashes white while it loads or resizes.
    private func paintBackground() {
        let color = Theme.hex(UInt32(look.background.dropFirst(), radix: 16) ?? 0)
        webView.underPageBackgroundColor = color
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    // MARK: WKNavigationDelegate

    /// The page is up, in the terminal's colours: the web view shows.
    func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
        webView.isHidden = false
        if wantsFocus {
            wantsFocus = false
            focus()
        }
    }

    /// Only the bundled page loads in the terminal; links go nowhere.
    func webView(
        _: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }

    /// The page's process ended (memory pressure…): load it again; the program keeps running.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        session.pageWillReload()
        webView.reload()
    }
}

/// Passes the page's messages on without WebKit keeping the view alive.
@MainActor
private final class TerminalMessageHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((Any) -> Void)?

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage?(message.body)
    }
}
