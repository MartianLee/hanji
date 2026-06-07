# hanji — Rich Renderers (Images, Mermaid, Dataview-lite) Plan

> REQUIRED SUB-SKILL: superpowers:executing-plans. Branch `rich-renderers` (off `main`).
> Scope note: three substantial first-cut features built on the renderer/overlay mechanism. Implemented + verified in sequence.

**Goal:** Inline rendering of (1) **images** (`![[file]]` / `![alt](path)`), (2) **mermaid** diagrams (` ```mermaid `), and (3) **Dataview-lite** (` ```dataview ` with `LIST FROM #tag`).

**Shared foundation:** Generalize the editor's widget placement so any widget reserves the **height it actually needs** (measured via `NSHostingView.fittingSize`, capped), by setting `minimumLineHeight` on the block's first line + collapsing the rest, then overlaying. Caret inside the block → raw source (no widget), as today.

**Conventions:** branch `rich-renderers`; UTF-16 offsets; `Checks` runner; commit trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## Task 1: Editor — general widget placement (fittingSize height reservation)

Refactor `Coordinator.updateBlockViews()` so each widget = `(key, region: Range<Int>, view: AnyView)`:
1. Collect widgets (code blocks with a registered renderer; images added in Task 2).
2. For each (caret outside region): host the `AnyView`, set width = text container width − insets, read `host.fittingSize.height` (cap 600).
3. Reserve: on the region's **first line** set `paragraphStyle.minimumLineHeight = h`; on the region's other lines set near-zero font; set `foregroundColor = .clear` over the whole region (hide source).
4. `tlm.ensureLayout`; position the host over the region's segment rect.
5. Sync (remove stale). `overlays: [String: NSHostingView<AnyView>]`.

Verify: existing `card` block still renders (now auto-sized). Commit `refactor(editor): fittingSize-based widget height reservation`.

---

## Task 2: Images

**MarkdownCore — `ImageParser`** (`Sources/MarkdownCore/ImageRef.swift`): own-line image refs.

```swift
import Foundation

public struct ImageRef: Equatable {
    public let path: String
    public let line: Range<Int>
    public init(path: String, line: Range<Int>) { self.path = path; self.line = line }
}

public enum ImageParser {
    public static func images(in text: String) -> [ImageRef] {
        var out: [ImageRef] = []
        let ns = text as NSString
        let nl = UInt16(UnicodeScalar("\n").value)
        var start = 0
        while start <= ns.length {
            var end = start
            while end < ns.length && ns.character(at: end) != nl { end += 1 }
            let raw = ns.substring(with: NSRange(location: start, length: end - start))
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("![["), line.hasSuffix("]]") {
                var inner = String(line.dropFirst(3).dropLast(2))
                if let bar = inner.firstIndex(of: "|") { inner = String(inner[..<bar]) }
                if !inner.isEmpty { out.append(ImageRef(path: inner, line: start..<end)) }
            } else if line.hasPrefix("!["), line.hasSuffix(")"), let p = line.range(of: "](") {
                let path = String(line[p.upperBound...].dropLast())
                if !path.isEmpty { out.append(ImageRef(path: path, line: start..<end)) }
            }
            if end == ns.length { break }
            start = end + 1
        }
        return out
    }
}
```

Checks (`ImageParserChecks`): `![[test.png]]` → path "test.png"; `![a](img/p.png)` → "img/p.png"; `![[a.png|200]]` → "a.png"; plain line → none.

**Editor:** add `var vaultRoot: URL?` to `MarkdownEditorView`; `ContentView` passes `appState.vaultRoot`. In widget collection, for each `ImageRef` (caret outside): resolve `vaultRoot.appendingPathComponent(path)`, `NSImage(contentsOf:)`; if ok add widget `AnyView(Image(nsImage:).resizable().scaledToFit().frame(maxHeight: 320))` over `img.line`.

Verify (screenshot): a note with `![[test.png]]` shows the image; caret on the line shows the raw `![[test.png]]`. Commit `feat: inline image rendering`.

---

## Task 3: Mermaid (WKWebView)

**CoreRenderers — `MermaidRenderer`** for language `mermaid`: returns a WebView (NSViewRepresentable over `WKWebView`) at a fixed `.frame(height: 320)` (so fittingSize = 320) loading an HTML page that renders the source via mermaid.js from a CDN.

```swift
import SwiftUI
import WebKit
import ExtensionSDK

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
        <script>mermaid.initialize({startOnLoad:true});</script>
        <style>body{margin:0;font-family:-apple-system}</style></head>
        <body><pre class="mermaid">\(escaped)</pre></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }
}
```

Register `MermaidRenderer()` in the app. Verify (screenshot, needs network): a ` ```mermaid ` block with `graph TD; A-->B;` renders a diagram. Commit `feat(renderers): mermaid via WKWebView`. (Note limitation: requires network for the CDN.)

---

## Task 4: Dataview-lite (`LIST FROM #tag`)

**MarkdownCore — tags:** `Sources/MarkdownCore/Tags.swift` `Tags.extract(from:) -> [String]` (scan `#word`, dedup). Checks.

**VaultKit — index tags:** add `tags: [String]` to `NoteMeta`; `MetadataIndex.build` fills it via `Tags.extract`; add `func notes(withTag tag: String) -> [NoteMeta]`. Checks (temp vault with `#daily`).

**DQL-lite:** `Sources/MarkdownCore/DataviewQuery.swift` parse `LIST FROM #tag` → tag string (nil if unsupported). Checks.

**CoreRenderers — `DataviewRenderer`** (language `dataview`), constructed with `indexProvider: () -> MetadataIndex` (CoreRenderers gains a VaultKit dep): parse the source query; run `notes(withTag:)`; render a bullet list of titles (or "Unsupported query"). The app registers `DataviewRenderer(indexProvider: { appState.index })`.

Verify (screenshot): a note with a `#proj` tag elsewhere + a ` ```dataview \n LIST FROM #proj \n ``` ` block renders a list including that note. Commit `feat(renderers): Dataview-lite LIST FROM #tag`.

---

## Task 5: Wrap + finish

- README: add images / mermaid / Dataview-lite to status.
- `swift run Checks` green; copy plan to repo `docs/`; commit.
- superpowers:finishing-a-development-branch → merge `rich-renderers` → `main`.

---

## Self-Review

**Scope:** Three first-cut features; each verified by screenshot. Limitations noted: mermaid needs network (CDN); Dataview-lite supports only `LIST FROM #tag`; images resolve relative to vault root (no whole-vault filename search yet). ✓
**Risk:** Task 1 (height reservation) is the shared spike; Tasks 2–4 build on it. Dataview needs index tags (Task 4 extends `NoteMeta`). ✓
