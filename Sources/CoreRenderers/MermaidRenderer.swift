import SwiftUI
import WebKit
import ExtensionSDK

/// Renders a ```mermaid block as a diagram via mermaid.js in a WKWebView, sized to
/// the rendered diagram's height (no fixed padding).
/// Note: loads a pinned, integrity-checked mermaid.js from a CDN, so it needs
/// network access at runtime.
public struct MermaidRenderer: CodeBlockRenderer {
    public let language = "mermaid"
    public init() {}
    public func makeView(source: String) -> AnyView {
        AnyView(WebBlockView(minHeight: 40, maxHeight: 600,
                             page: { MermaidPage.html(source: source, nonce: $0) },
                             allowsNavigation: MermaidPage.allowsNavigation, baseURL: MermaidPage.baseURL))
    }
}

/// The page a mermaid block renders in, and what it may navigate to.
///
/// The block's text comes from the note — possibly from a vault someone else
/// wrote — so it reaches mermaid only as a string literal set via `textContent`,
/// never as markup. Behind that, a CSP limits script to the pinned mermaid build
/// and this page's own nonce-tagged script, and allows no fetch/XHR destinations
/// or remote images, so even injected script would have nowhere to send anything.
public enum MermaidPage {
    /// `.invalid` is reserved (RFC 2606): it never resolves, so no host can claim it.
    public static let baseURL = URL(string: "https://hanji.invalid/")!

    static let mermaidURL = "https://cdn.jsdelivr.net/npm/mermaid@10.9.8/dist/mermaid.min.js"
    static let mermaidIntegrity = "sha384-N3QqR/7q+xm3BGX+CBbNI8AUmRRqcsDzToy+0z1NLDI0QmTKW8zvwLvqulJgk3dP"

    public static func html(source: String, nonce: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; \
        script-src 'nonce-\(nonce)' https://cdn.jsdelivr.net/npm/mermaid@10.9.8/; \
        style-src 'unsafe-inline'; img-src data:; font-src data:">
        <script nonce="\(nonce)" src="\(mermaidURL)" integrity="\(mermaidIntegrity)" crossorigin="anonymous"></script>
        <style>html,body{margin:0;padding:0}#d{display:inline-block;font-family:-apple-system,sans-serif}</style>
        </head><body><div id="d" class="mermaid"></div>
        <script nonce="\(nonce)">
        function report(){
          var el = document.getElementById('d');
          var h = el ? el.getBoundingClientRect().height : 0;
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mkHeight)
            window.webkit.messageHandlers.mkHeight.postMessage(Math.ceil(h));
        }
        document.getElementById('d').textContent = \(PageText.jsStringLiteral(source));
        (async function(){
          try { mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' }); await mermaid.run({ querySelector: '.mermaid' }); }
          catch(e) {}
          requestAnimationFrame(function(){ requestAnimationFrame(report); });
        })();
        </script>
        </body></html>
        """
    }

    /// Only the initial `loadHTMLString` load. Links, reloads and anything a
    /// script tries (`location = …`) are refused.
    public static func allowsNavigation(to url: URL?, type: WKNavigationType) -> Bool {
        type == .other && url == baseURL
    }
}
