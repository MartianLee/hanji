import SwiftUI
import WebKit
import ExtensionSDK

/// Renders a ```mermaid block as a diagram via mermaid.js in a WKWebView.
/// Note: loads mermaid.js from a CDN, so it needs network access at runtime.
public struct MermaidRenderer: CodeBlockRenderer {
    public let language = "mermaid"
    public init() {}
    public func makeView(source: String) -> AnyView {
        AnyView(MermaidWeb(source: source).frame(height: 320))
    }
}

private struct MermaidWeb: NSViewRepresentable {
    let source: String

    func makeNSView(context: Context) -> WKWebView { WKWebView() }

    func updateNSView(_ web: WKWebView, context: Context) {
        let escaped = source.replacingOccurrences(of: "</", with: "<\\/")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
        <script>mermaid.initialize({ startOnLoad: true });</script>
        <style>body{margin:0;font-family:-apple-system,sans-serif}</style>
        </head><body><pre class="mermaid">\(escaped)</pre></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://hanji.local/"))
    }
}
