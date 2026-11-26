import WebKit

/// A private content world keeps page scripts out of Gita's bridge. Both the message and the
/// programmatic scroll carry fractions, so panes with different document heights stay aligned.
@MainActor
final class VisualPreviewScrollSync: NSObject, WKScriptMessageHandler {
    private static let name = "gitaScroll"
    private static let world = WKContentWorld.world(name: "GitaVisualComparison")
    private weak var production: WKWebView?
    private weak var preview: WKWebView?

    private static let script = """
        (() => {
          const page = () => document.scrollingElement || document.documentElement;
          let expected = null;
          let scheduled = false;
          globalThis.gitaScrollTo = (x, y) => {
            const root = page();
            const left = x * Math.max(0, root.scrollWidth - root.clientWidth);
            const top = y * Math.max(0, root.scrollHeight - root.clientHeight);
            expected = [left, top];
            window.scrollTo({left, top, behavior: 'instant'});
          };
          window.addEventListener('scroll', () => {
            if (scheduled) return;
            scheduled = true;
            requestAnimationFrame(() => {
              scheduled = false;
              const same = expected && Math.abs(scrollX - expected[0]) < 2 && Math.abs(scrollY - expected[1]) < 2;
              expected = null;
              if (same) return;
              const root = page();
              window.webkit.messageHandlers.gitaScroll.postMessage([
                scrollX / Math.max(1, root.scrollWidth - root.clientWidth),
                scrollY / Math.max(1, root.scrollHeight - root.clientHeight)
              ]);
            });
          }, {passive: true});
        })();
        """

    init(production: WKWebView, preview: WKWebView) {
        self.production = production
        self.preview = preview
        super.init()
        let script = WKUserScript(
            source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
            in: Self.world)
        for web in [production, preview] {
            let content = web.configuration.userContentController
            content.addUserScript(script)
            content.add(self, contentWorld: Self.world, name: Self.name)
        }
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let values = message.body as? [Double], values.count == 2,
            values.allSatisfy(\.isFinite), let web = message.webView
        else { return }
        let target = web === production ? preview : production
        let x = min(1, max(0, values[0]))
        let y = min(1, max(0, values[1]))
        target?.callAsyncJavaScript(
            "globalThis.gitaScrollTo?.(x, y)", arguments: ["x": x, "y": y],
            in: nil, in: Self.world, completionHandler: nil)
    }

    func tearDown() {
        for web in [production, preview].compactMap({ $0 }) {
            let content = web.configuration.userContentController
            content.removeScriptMessageHandler(forName: Self.name, contentWorld: Self.world)
            content.removeAllUserScripts()
        }
        production = nil
        preview = nil
    }
}
