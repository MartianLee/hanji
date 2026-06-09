import SwiftUI
import WebKit
import ExtensionSDK

/// Renders a ```mermaid block as a diagram via mermaid.js in a WKWebView, sized to
/// the rendered diagram's height (no fixed padding).
/// Note: loads mermaid.js from a CDN, so it needs network access at runtime.
public struct MermaidRenderer: CodeBlockRenderer {
    public let language = "mermaid"
    public init() {}
    public func makeView(source: String) -> AnyView {
        AnyView(MermaidView(source: source))
    }
}

private final class MermaidHeight: ObservableObject {
    @Published var height: CGFloat = 60
}

private struct MermaidView: View {
    let source: String
    @StateObject private var model = MermaidHeight()
    var body: some View {
        MermaidWeb(source: source, model: model)
            .frame(height: model.height)
    }
}

private struct MermaidWeb: NSViewRepresentable {
    let source: String
    @ObservedObject var model: MermaidHeight

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "mkHeight")
        let web = WKWebView(frame: .zero, configuration: config)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.model = model
        let escaped = source.replacingOccurrences(of: "</", with: "<\\/")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
        <style>html,body{margin:0;padding:0}#d{display:inline-block;font-family:-apple-system,sans-serif}</style>
        </head><body><div id="d" class="mermaid">\(escaped)</div>
        <script>
        function report(){
          var el = document.getElementById('d');
          var h = el ? el.getBoundingClientRect().height : 0;
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mkHeight)
            window.webkit.messageHandlers.mkHeight.postMessage(Math.ceil(h));
        }
        (async function(){
          try { mermaid.initialize({ startOnLoad: false }); await mermaid.run({ querySelector: '.mermaid' }); }
          catch(e) {}
          requestAnimationFrame(function(){ requestAnimationFrame(report); });
        })();
        </script>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://hanji.local/"))
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var model: MermaidHeight
        init(model: MermaidHeight) { self.model = model }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double else { return }
            let clamped = min(max(40, CGFloat(value) + 8), 600)
            guard abs(clamped - model.height) > 1 else { return }
            DispatchQueue.main.async {
                self.model.height = clamped
                // Let the editor re-measure and re-reserve the inline widget's space.
                NotificationCenter.default.post(name: .hanjiWidgetDidResize, object: nil)
            }
        }
    }
}
