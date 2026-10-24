import SwiftUI
import WebKit
import ExtensionSDK

/// A code block drawn by a web page (mermaid, KaTeX), sized to the height the
/// page reports through the `mkHeight` message — no fixed padding.
struct WebBlockView: View {
    let minHeight: CGFloat
    let maxHeight: CGFloat
    /// The page's HTML, given a fresh nonce for its CSP.
    let page: (_ nonce: String) -> String
    let allowsNavigation: (URL?, WKNavigationType) -> Bool
    let baseURL: URL
    @StateObject private var model = WebBlockHeight()

    var body: some View {
        WebBlockWeb(block: self, model: model)
            .frame(height: model.height)
    }
}

private final class WebBlockHeight: ObservableObject {
    @Published var height: CGFloat = 60
}

private struct WebBlockWeb: NSViewRepresentable {
    let block: WebBlockView
    @ObservedObject var model: WebBlockHeight

    func makeCoordinator() -> Coordinator { Coordinator(block: block, model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nothing a block does should outlive it or be visible to another note's.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "mkHeight")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.block = block
        context.coordinator.model = model
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        web.loadHTMLString(block.page(nonce), baseURL: block.baseURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var block: WebBlockView
        var model: WebBlockHeight
        init(block: WebBlockView, model: WebBlockHeight) { self.block = block; self.model = model }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowed = action.targetFrame?.isMainFrame == true
                && block.allowsNavigation(action.request.url, action.navigationType)
            decisionHandler(allowed ? .allow : .cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double else { return }
            let clamped = min(max(block.minHeight, CGFloat(value) + 8), block.maxHeight)
            guard abs(clamped - model.height) > 1 else { return }
            DispatchQueue.main.async {
                self.model.height = clamped
                // Let the editor re-measure and re-reserve the inline widget's space.
                NotificationCenter.default.post(name: .hanjiWidgetDidResize, object: nil)
            }
        }
    }
}

/// Note text on its way into a page.
enum PageText {
    /// `text` as a JavaScript string literal that is also inert inside a
    /// `<script>` element: JSON escaping plus every `<` as `<`, so neither
    /// `</script>` nor `<!--` can change how the HTML parser reads the block.
    static func jsStringLiteral(_ text: String) -> String {
        let json = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return json.replacingOccurrences(of: "<", with: "\\u003C")
    }
}
