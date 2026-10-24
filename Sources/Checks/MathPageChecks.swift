import Foundation
import WebKit
import CoreRenderers

/// A formula comes from the note — possibly a vault someone else wrote — so it
/// must reach KaTeX as data, never as markup the page runs.
func mathPageChecks() {
    let nonce = "N0nce"
    func page(_ source: String) -> String { MathPage.html(source: source, nonce: nonce) }
    expect(!page("</script><script>alert(1)</script>").contains("<script>alert"), "a closing script tag can't break out")
    expect(!page("<img src=x onerror=alert(1)>").contains("<img"), "note text never lands as an HTML tag")
    let plain = page("e^{i\\pi}+1=0")
    expect(plain.contains("\"e^{i\\\\pi}+1=0\""), "the formula is passed as a string literal")
    expect(plain.contains("default-src 'none'"), "a CSP denies everything not listed")
    expect(plain.contains("'nonce-\(nonce)'"), "only nonce-tagged inline script runs")
    expect(!plain.contains("connect-src"), "no fetch/XHR destinations")
    expect(plain.contains("katex@0.18.11/"), "KaTeX is pinned to an exact version")
    expect(plain.contains("sha384-vaygNa7Kw+54Zb42f7K+4bfhZp4vWSHPJMKwd7nVmlgSvRADUrCRRdCpc1/CJwO+"), "the script is integrity-checked")
    expect(plain.contains("sha384-NJ/T2p1ROqNH3Yico+wdWm5Rv2rlinAOvV25Sw1zLOaxg8yLDPVv8GGAUccx50rh"), "the stylesheet is integrity-checked")
    expect(plain.contains("trust: false"), "KaTeX may not run \\href / \\url / html commands")
    expect(MathPage.allowsNavigation(to: MathPage.baseURL, type: .other), "the page itself loads")
    expect(!MathPage.allowsNavigation(to: URL(string: "https://evil.example/"), type: .linkActivated), "links don't navigate")
}
