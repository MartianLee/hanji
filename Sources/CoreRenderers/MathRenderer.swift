import SwiftUI
import WebKit
import ExtensionSDK

/// Renders a `$$` (or ```math) block as a display formula with KaTeX, loaded
/// pinned and integrity-checked from a CDN — like mermaid, it needs network
/// access at runtime.
public struct MathRenderer: CodeBlockRenderer {
    public let language = "math"
    public init() {}
    public func makeView(source: String) -> AnyView {
        AnyView(WebBlockView(minHeight: 24, maxHeight: 400,
                             page: { MathPage.html(source: source, nonce: $0) },
                             allowsNavigation: MathPage.allowsNavigation, baseURL: MathPage.baseURL))
    }
}

/// The page a math block renders in. Same rules as `MermaidPage`: the formula
/// arrives as a string literal, a CSP admits only the pinned KaTeX build and
/// this page's nonce-tagged script, and nothing may be fetched or navigated to.
/// KaTeX runs with `trust: false`, so `\href`, `\url` and HTML commands render
/// as errors rather than links.
public enum MathPage {
    /// `.invalid` is reserved (RFC 2606): it never resolves, so no host can claim it.
    public static let baseURL = URL(string: "https://hanji.invalid/")!

    static let base = "https://cdn.jsdelivr.net/npm/katex@0.18.11/dist/"
    static let scriptIntegrity = "sha384-vaygNa7Kw+54Zb42f7K+4bfhZp4vWSHPJMKwd7nVmlgSvRADUrCRRdCpc1/CJwO+"
    static let styleIntegrity = "sha384-NJ/T2p1ROqNH3Yico+wdWm5Rv2rlinAOvV25Sw1zLOaxg8yLDPVv8GGAUccx50rh"

    public static func html(source: String, nonce: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; \
        script-src 'nonce-\(nonce)' \(base); style-src 'unsafe-inline' \(base); font-src \(base); img-src data:">
        <link rel="stylesheet" href="\(base)katex.min.css" integrity="\(styleIntegrity)" crossorigin="anonymous">
        <script nonce="\(nonce)" src="\(base)katex.min.js" integrity="\(scriptIntegrity)" crossorigin="anonymous"></script>
        <style>html,body{margin:0;padding:0;background:transparent}#m{display:inline-block;min-width:100%;font-size:1.1em}\
        .katex-display{margin:4px 0}.err{color:#d33;font:12px ui-monospace,monospace;white-space:pre-wrap}</style>
        </head><body><div id="m"></div>
        <script nonce="\(nonce)">
        function report(){
          var el = document.getElementById('m');
          var h = el ? el.getBoundingClientRect().height : 0;
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mkHeight)
            window.webkit.messageHandlers.mkHeight.postMessage(Math.ceil(h));
        }
        var src = \(PageText.jsStringLiteral(source));
        var el = document.getElementById('m');
        if (typeof katex === 'undefined') { el.className = 'err'; el.textContent = src + '\\n(KaTeX could not load — offline?)'; }
        else {
          try { katex.render(src, el, { displayMode: true, throwOnError: true, trust: false, strict: 'ignore', maxExpand: 1000, maxSize: 50 }); }
          catch (e) { el.className = 'err'; el.textContent = (e && e.message) ? e.message : String(e); }
        }
        requestAnimationFrame(function(){ requestAnimationFrame(report); });
        </script>
        </body></html>
        """
    }

    /// Only the initial `loadHTMLString` load; links and scripted navigation are refused.
    public static func allowsNavigation(to url: URL?, type: WKNavigationType) -> Bool {
        type == .other && url == baseURL
    }
}
