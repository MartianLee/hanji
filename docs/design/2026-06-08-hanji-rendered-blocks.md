# hanji — Rendered Blocks (RendererRegistry + inline widget spike) Plan

**Goal:** Open the SDK's renderer surface ① — a `CodeBlockRenderer` + `RendererRegistry` that plugins register into — and render a fenced code block whose language has a registered renderer as an **inline widget** in the TextKit 2 editor, **without mutating the document text** (the source is preserved and revealed when the caret enters the block). First built-in renderer is a simple boxed "card" renderer (` ```card `) to prove the whole pipeline end-to-end; mermaid / Dataview tables / images build on this later.

**Architecture:** `MarkdownCore` gains a block-level `CodeBlockRegion` (language + ranges). `ExtensionSDK` defines `CodeBlockRenderer` + `RendererRegistry` and adds `renderers` to `PluginHost`. `AppCore` provides `DefaultRendererRegistry` and wires it into `Host`. `EditorEngine` renders registered blocks via a TextKit 2 mechanism (the spike). A `CoreRenderers` target ships `CardRenderer`, registered by the app.

**Tech Stack:** Swift 5 / SPM; AppKit/TextKit 2 (`NSTextLayoutManagerDelegate` / `NSTextLayoutFragment` or `NSTextAttachmentViewProvider`); SwiftUI via `NSHostingView`; `Checks` runner + screenshot E2E.

**Reference spec:** `docs/design/2026-06-06-native-markdown-editor-design.md` (§5.3 inline blocks, §5.4 `CodeBlockRenderer`, R1-style spike).

**Conventions:** branch `rendered-blocks`; UTF-16 offsets; check-groups in `Sources/Checks/`.

---

## Task 1: MarkdownCore — CodeBlockRegion (block-level parse)

The per-line `.codeBlock` spans (M2d) drive styling; rendering needs the block as a unit with its language.

**Files:** Create `Sources/MarkdownCore/CodeBlockRegion.swift`; create `Sources/Checks/CodeBlockRegionChecks.swift`; modify `Sources/Checks/main.swift`.

- [ ] **Step 1: Model + parser** `Sources/MarkdownCore/CodeBlockRegion.swift`

```swift
import Foundation

public struct CodeBlockRegion: Equatable {
    public let language: String        // "" if none
    public let body: Range<Int>        // inner text (between fences), UTF-16
    public let full: Range<Int>        // whole block incl fences
    public init(language: String, body: Range<Int>, full: Range<Int>) {
        self.language = language; self.body = body; self.full = full
    }
}

public enum CodeBlockParser {
    /// Finds fenced code blocks (``` …). A block opens on a line starting with ```
    /// (optionally followed by a language) and closes on the next line that is ```.
    public static func regions(in text: String) -> [CodeBlockRegion] {
        var out: [CodeBlockRegion] = []
        let ns = text as NSString
        let length = ns.length
        let newline = UInt16(UnicodeScalar("\n").value)

        var lineStart = 0
        var open: (fenceStart: Int, bodyStart: Int, lang: String)? = nil
        while lineStart <= length {
            var lineEnd = lineStart
            while lineEnd < length && ns.character(at: lineEnd) != newline { lineEnd += 1 }
            let line = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let isFence = line.hasPrefix("```")
            if let o = open {
                if isFence {
                    let body = o.bodyStart..<(lineStart > o.bodyStart ? lineStart - 1 : o.bodyStart)
                    out.append(CodeBlockRegion(language: o.lang, body: body, full: o.fenceStart..<lineEnd))
                    open = nil
                }
            } else if isFence {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let bodyStart = (lineEnd == length) ? lineEnd : lineEnd + 1
                open = (fenceStart: lineStart, bodyStart: bodyStart, lang: lang)
            }
            if lineEnd == length { break }
            lineStart = lineEnd + 1
        }
        return out
    }
}
```

- [ ] **Step 2: Checks** `Sources/Checks/CodeBlockRegionChecks.swift`

```swift
import MarkdownCore

func codeBlockRegionChecks() {
    let r = CodeBlockParser.regions(in: "a\n```card\nhello\n```\nb")
    expectEqual(r.count, 1, "one code block region")
    expectEqual(r.first?.language, "card", "language parsed from fence")
    // "a\n"(0..2) "```card\n"(2..10) "hello\n"(10..16) "```"(16..19) "\nb"
    expectEqual(r.first?.body, 10..<15, "body is the inner line 'hello'")
    expect(r.first!.full.lowerBound == 2, "full starts at opening fence")

    let none = CodeBlockParser.regions(in: "no fences here")
    expectEqual(none.count, 0, "no regions without fences")
}
```

- [ ] **Step 3:** Register `("CodeBlockRegion", codeBlockRegionChecks)` in `main.swift`; run `swift run Checks CodeBlockRegion` (red→green); commit `feat(core): parse fenced code-block regions with language`.

---

## Task 2: ExtensionSDK — CodeBlockRenderer + RendererRegistry (surface ①)

**Files:** Modify `Sources/ExtensionSDK/ExtensionSDK.swift`.

- [ ] **Step 1: Add protocols + host hook**

```swift
/// Surface ①: renders a fenced code block of a given language as a view.
public protocol CodeBlockRenderer {
    var language: String { get }
    func makeView(source: String) -> AnyView
}

/// Where plugins register code-block renderers.
public protocol RendererRegistry: AnyObject {
    func register(_ renderer: CodeBlockRenderer)
    func renderer(for language: String) -> CodeBlockRenderer?
}
```

And add to `PluginHost`:
```swift
    var renderers: RendererRegistry { get }
```

- [ ] **Step 2: Build.** `swift build` will fail until `Host` (Task 3) conforms — that's expected; do Task 3 next, then build. Commit happens at the end of Task 3.

---

## Task 3: AppCore — DefaultRendererRegistry + Host wiring

**Files:** Create `Sources/AppCore/DefaultRendererRegistry.swift`; modify `Sources/AppCore/Host.swift`; create `Sources/Checks/RendererRegistryChecks.swift`; modify `main.swift`.

- [ ] **Step 1: Registry** `Sources/AppCore/DefaultRendererRegistry.swift`

```swift
import ExtensionSDK

public final class DefaultRendererRegistry: RendererRegistry {
    private var byLanguage: [String: CodeBlockRenderer] = [:]
    public init() {}
    public func register(_ renderer: CodeBlockRenderer) { byLanguage[renderer.language] = renderer }
    public func renderer(for language: String) -> CodeBlockRenderer? { byLanguage[language] }
}
```

- [ ] **Step 2: Wire into `Host`** — add a stored `DefaultRendererRegistry` and expose it. In `Host`:
  - add property: `private let rendererRegistry = DefaultRendererRegistry()`
  - add conformance: `public var renderers: RendererRegistry { rendererRegistry }`

- [ ] **Step 3: Checks** `Sources/Checks/RendererRegistryChecks.swift`

```swift
import SwiftUI
import ExtensionSDK
@testable import AppCore

private struct FakeRenderer: CodeBlockRenderer {
    let language = "card"
    func makeView(source: String) -> AnyView { AnyView(Text(source)) }
}

func rendererRegistryChecks() {
    let reg = DefaultRendererRegistry()
    reg.register(FakeRenderer())
    expect(reg.renderer(for: "card") != nil, "renderer found by language")
    expect(reg.renderer(for: "nope") == nil, "unknown language returns nil")
}
```

- [ ] **Step 4:** Register `("RendererRegistry", rendererRegistryChecks)` in `main.swift`; `swift run Checks` (green); `swift build`; commit `feat(sdk,appcore): code-block renderer registry (surface ①)`.

---

## Task 4: CoreRenderers — CardRenderer + register in app

**Files:** Create `Sources/CoreRenderers/CardRenderer.swift`; modify `Package.swift` (new target `CoreRenderers` dep `ExtensionSDK`; add to `HanjiApp` deps); modify `Sources/HanjiApp/HanjiApp.swift` (register it).

- [ ] **Step 1: Package** — add `.target(name: "CoreRenderers", dependencies: ["ExtensionSDK"]),` and add `"CoreRenderers"` to the `HanjiApp` executable target deps.

- [ ] **Step 2: Renderer** `Sources/CoreRenderers/CardRenderer.swift`

```swift
import SwiftUI
import ExtensionSDK

public struct CardRenderer: CodeBlockRenderer {
    public let language = "card"
    public init() {}
    public func makeView(source: String) -> AnyView {
        AnyView(
            Text(source)
                .font(.body)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.4)))
        )
    }
}
```

- [ ] **Step 3: Register in the app** — in `HanjiApp.swift`, after plugin activation, register the renderer:
```swift
                    let host = Host(appState: appState, pluginManager: pluginManager)
                    host.renderers.register(CardRenderer())   // (import CoreRenderers)
                    let plugins: [Plugin] = [WordCountPlugin()]
                    pluginManager.activate(plugins, host: host)
```
Add `import CoreRenderers`. **Retain `host`** for the editor to use it (next task): store it in an `@State` or pass its registry to the editor.

- [ ] **Step 4:** `swift build`; commit `feat(renderers): built-in CardRenderer`.

---

## Task 5: EditorEngine — render registered blocks inline (THE SPIKE)

Render each `CodeBlockRegion` whose `language` has a registered renderer as an inline view, **without changing the text**, and reveal the raw source when the caret is inside the block.

**Spike decision (do first):** evaluate, in this order, a non-mutating mechanism:
1. **`NSTextLayoutManagerDelegate` + custom `NSTextLayoutFragment`** for the block's paragraphs — host the renderer's view via `NSHostingView` positioned at the fragment frame. (Preferred: non-mutating.)
2. If (1) proves intractable in a timebox, fall back to an **overlay `NSHostingView`** positioned from TextKit 2 layout geometry (`NSTextLayoutManager.enumerateTextLayoutFragments`) for the block range, with the underlying lines hidden via the existing near-zero-font technique.

**Files:** modify `Sources/EditorEngine/MarkdownEditorView.swift` (+ a new `Sources/EditorEngine/BlockRenderManager.swift`); pass the `RendererRegistry` into `MarkdownEditorView`.

- [ ] **Step 1:** Thread the registry in — `MarkdownEditorView(text:, renderers:)` gains a `RendererRegistry?` parameter; `ContentView` passes `appState`/host's registry. (Update `ContentView` + `AppState` to hold the registry, or pass via the App.)

- [ ] **Step 2:** Implement `BlockRenderManager` using the chosen mechanism. For each region with a registered renderer and the caret NOT inside `region.full`: display `renderer.makeView(source:)` (wrapped in `NSHostingView`) over the block; when the caret is inside, show raw source (no widget).

- [ ] **Step 3 (verify — spike success criteria):** Build, then E2E: add a ` ```card … ``` ` block to the demo vault; launch via `HANJI_OPEN_VAULT` + screenshot. Expected: the card block shows the boxed rendered view; moving the caret into it (`HANJI_CARET` inside the block) reveals the raw ` ```card ` source. Read the screenshot to confirm. **If neither mechanism yields a clean result in the timebox, stop and report findings** (this is a genuine spike).

- [ ] **Step 4:** Commit `feat(editor): inline rendering of registered code blocks (spike)`.

---

## Task 6: Wrap

- [ ] README: note "extensible code-block renderers (SDK surface ①) + built-in card renderer".
- [ ] `swift run Checks` (green); copy this plan into repo `docs/`; commit.
- [ ] Merge `rendered-blocks` → `main`.

---

## Self-Review

**Spec coverage:** Opens §5.4 `CodeBlockRenderer` + the §5.3 inline-render mechanism (surface ①). Images/callouts/mermaid/Dataview are follow-ons built on this registry + mechanism. ✓
**Placeholder scan:** Task 5 is explicitly a spike with ordered mechanisms + a stop-and-report fallback — not a vague step. ✓
**Type consistency:** `CodeBlockRegion(language:body:full:)`, `CodeBlockParser.regions(in:)`, `CodeBlockRenderer{language, makeView(source:)->AnyView}`, `RendererRegistry{register, renderer(for:)}`, `DefaultRendererRegistry`, `Host.renderers`, `CardRenderer`. ✓
**Risk:** Task 5 is the real risk (TextKit 2 view hosting). Tasks 1–4 are low-risk, TDD'd, and deliver the SDK surface even if the spike needs iteration.
