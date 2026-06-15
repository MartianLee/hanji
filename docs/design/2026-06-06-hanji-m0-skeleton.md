# hanji M0 (Walking Skeleton) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a runnable native macOS markdown editor skeleton that opens a markdown vault, edits/saves a note in a TextKit 2 `NSTextView`, builds an in-memory metadata index, and proves the compile-time plugin loop with a Word Count sidebar plugin — packaged as a launchable `.app` built purely from Swift Package Manager.

**Architecture:** Protocol-oriented SPM multi-target workspace. Dependencies flow downward only: `HanjiApp(exe) → AppCore → {VaultKit, ExtensionSDK, EditorEngine, MarkdownCore}`; `VaultKit → MarkdownCore`; `WordCountPlugin → ExtensionSDK`. Plugins depend on `ExtensionSDK` only — never on the app. (Matches spec §4.)

**Tech Stack:** Swift 5 language mode (tools 5.10) on the Swift 6.3 toolchain, macOS 14+ deployment, SwiftUI app shell, AppKit `NSTextView` + TextKit 2 for the editor, and a lightweight `Checks` executable as the test runner (XCTest requires full Xcode; this machine has Command Line Tools only — confirmed during execution). **Zero external package dependencies in M0** (GRDB/SQLite deferred to M3).

**Reference spec:** `docs/superpowers/specs/2026-06-06-native-markdown-editor-design.md` (M0 in §10).

**Conventions for every task:**
- Work in `~/workspace/hanji` (created in Task 1). This is greenfield — no worktree needed.
- TDD: write the failing test, run it red, write minimal code, run it green, commit.
- **Every commit message must end with this trailer line** (one blank line before it):
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Run all checks with `swift run Checks` from the project root (or `swift run Checks <GroupName>` for one group).

## Testing approach (revised 2026-06-07 — CLT only, no XCTest)

XCTest ships with full Xcode, which is not installed here (Command Line Tools only). M0 uses a **zero-dependency executable test runner**: an `executableTarget` named `Checks` with a tiny assertion harness in `Sources/Checks/Expect.swift` (`Check`, `expect`, `expectEqual`, `runChecks`). Run it with `swift run Checks` (exits non-zero on failure).

**Translating each task's test step below into this runner:**
- Turn the XCTest snippet into a check-group function, e.g. `func fooChecks() { ... }`, in `Sources/Checks/FooChecks.swift`.
- Register it in `Sources/Checks/main.swift`: add `("Foo", fooChecks)` to the `runChecks([...])` array.
- Add the module under test to the `Checks` target's `dependencies` in `Package.swift`.
- Develop red→green on one group: `swift run Checks Foo`.
- Assertion mapping: `XCTAssertEqual(a, b)` → `expectEqual(a, b, "desc")`; `XCTAssertTrue(x)`/`XCTAssert(x)` → `expect(x, "desc")`.
- Use a plain `import Module` (not `@testable`) — every asserted API in this plan is `public`.

---

## Task 1: Project init + SPM skeleton + build-system spike (de-risks R2)

**Why first:** The single biggest unknown is whether this machine (Command Line Tools only, no full Xcode) can build and launch a SwiftUI GUI from SPM. Prove it with the smallest possible app before building anything else.

**Files:**
- Create: `~/workspace/hanji/Package.swift`
- Create: `~/workspace/hanji/.gitignore`
- Create: `~/workspace/hanji/Sources/HanjiApp/HanjiApp.swift`

- [ ] **Step 1: Create project dir and init git**

```bash
mkdir -p ~/workspace/hanji/Sources/HanjiApp
cd ~/workspace/hanji
git init
```

- [ ] **Step 2: Write `.gitignore`**

```
.build/
*.app
.DS_Store
*.xcodeproj
```

- [ ] **Step 3: Write `Package.swift`** (exe target only for now)

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "hanji",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hanji", targets: ["HanjiApp"])
    ],
    targets: [
        .executableTarget(name: "HanjiApp")
    ]
)
```

- [ ] **Step 4: Write the minimal SwiftUI app** `Sources/HanjiApp/HanjiApp.swift`

```swift
import SwiftUI
import AppKit

@main
struct HanjiApp: App {
    var body: some Scene {
        WindowGroup {
            Text("hanji skeleton")
                .frame(width: 360, height: 200)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
    }
}
```

- [ ] **Step 5: Build (the real R2 gate)**

Run: `swift build`
Expected: `Build complete!` with no errors. **If this fails**, capture the error — it determines the M0 build strategy (may require installing full Xcode or `swift-bundler`; see spec §9/R2). Do not proceed until `swift build` succeeds.

- [ ] **Step 6: Launch to confirm a window appears**

Run: `swift run hanji`
Expected: a small window titled with "hanji skeleton" appears. Close it (⌘Q) to end the run. (If running over SSH/headless, a window may not display; a successful build + clean launch/exit is acceptable evidence for M0.)

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: SPM skeleton + SwiftUI build spike"
```

---

## Task 2: MarkdownCore — TitleExtractor (pure logic)

**Files:**
- Create: `Sources/MarkdownCore/TitleExtractor.swift`
- Test: `Tests/MarkdownCoreTests/TitleExtractorTests.swift`
- Modify: `Package.swift` (add `MarkdownCore` target + test target)

- [ ] **Step 1: Add targets to `Package.swift`**

Add these two entries to the `targets:` array:

```swift
        .target(name: "MarkdownCore"),
        .testTarget(name: "MarkdownCoreTests", dependencies: ["MarkdownCore"]),
```

- [ ] **Step 2: Write the failing test** `Tests/MarkdownCoreTests/TitleExtractorTests.swift`

```swift
import XCTest
@testable import MarkdownCore

final class TitleExtractorTests: XCTestCase {
    func test_returnsFirstH1() {
        XCTAssertEqual(TitleExtractor.title(fromMarkdown: "# Title\nx", fallback: "f"), "Title")
    }
    func test_fallbackWhenNoH1() {
        XCTAssertEqual(TitleExtractor.title(fromMarkdown: "no heading", fallback: "f"), "f")
    }
    func test_hashWithoutSpaceIsNotH1() {
        XCTAssertEqual(TitleExtractor.title(fromMarkdown: "#NoSpace", fallback: "f"), "f")
    }
    func test_h2IsNotH1() {
        XCTAssertEqual(TitleExtractor.title(fromMarkdown: "## H2", fallback: "f"), "f")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter TitleExtractorTests`
Expected: FAIL — `cannot find 'TitleExtractor' in scope`.

- [ ] **Step 4: Write minimal implementation** `Sources/MarkdownCore/TitleExtractor.swift`

```swift
import Foundation

public enum TitleExtractor {
    /// Returns the first ATX H1 ("# ...") text, else the fallback (e.g. filename).
    public static func title(fromMarkdown text: String, fallback: String) -> String {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
        }
        return fallback
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter TitleExtractorTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(core): add TitleExtractor"
```

---

## Task 3: VaultKit — Vault enumerate / read / atomic write

**Files:**
- Create: `Sources/VaultKit/Vault.swift`
- Test: `Tests/VaultKitTests/VaultTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add targets to `Package.swift`**

Add to the `targets:` array:

```swift
        .target(name: "VaultKit", dependencies: ["MarkdownCore"]),
        .testTarget(name: "VaultKitTests", dependencies: ["VaultKit"]),
```

- [ ] **Step 2: Write the failing test** `Tests/VaultKitTests/VaultTests.swift`

```swift
import XCTest
@testable import VaultKit

final class VaultTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hanji-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_markdownFiles_findsOnlyMarkdown_sortedByName() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let files = try Vault(root: root).markdownFiles()
        XCTAssertEqual(files.map(\.name), ["a.md", "b.md"])
    }

    func test_write_then_read_roundTrips() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("note.md")
        try "old".write(to: url, atomically: true, encoding: .utf8)
        let vault = Vault(root: root)
        let file = MarkdownFile(url: url)
        try vault.write("new content", to: file)
        XCTAssertEqual(try vault.read(file), "new content")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter VaultTests`
Expected: FAIL — `cannot find 'Vault' in scope`.

- [ ] **Step 4: Write minimal implementation** `Sources/VaultKit/Vault.swift`

```swift
import Foundation
import MarkdownCore

public struct MarkdownFile: Identifiable, Hashable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

public struct Vault {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// All `.md` files under root, recursively, sorted by full path.
    public func markdownFiles() throws -> [MarkdownFile] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [MarkdownFile] = []
        for case let url as URL in en where url.pathExtension.lowercased() == "md" {
            out.append(MarkdownFile(url: url))
        }
        return out.sorted { $0.url.path < $1.url.path }
    }

    public func read(_ file: MarkdownFile) throws -> String {
        try String(contentsOf: file.url, encoding: .utf8)
    }

    /// Atomic write: write a temp file in the same directory, then replace.
    public func write(_ text: String, to file: MarkdownFile) throws {
        let fm = FileManager.default
        let dir = file.url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(file.name).tmp-\(UUID().uuidString)")
        try Data(text.utf8).write(to: tmp)
        if fm.fileExists(atPath: file.url.path) {
            _ = try fm.replaceItemAt(file.url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: file.url)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter VaultTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(vault): enumerate, read, atomic write"
```

---

## Task 4: VaultKit — MetadataIndex (in-memory)

**Files:**
- Create: `Sources/VaultKit/MetadataIndex.swift`
- Test: `Tests/VaultKitTests/MetadataIndexTests.swift`

- [ ] **Step 1: Write the failing test** `Tests/VaultKitTests/MetadataIndexTests.swift`

```swift
import XCTest
@testable import VaultKit

final class MetadataIndexTests: XCTestCase {
    func test_build_extractsTitlesAndCounts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hanji-idx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Hello\nbody".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "no heading".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        let index = try MetadataIndex.build(from: Vault(root: root))

        XCTAssertEqual(index.notes.count, 2)
        XCTAssertEqual(index.note(forRelativePath: "a.md")?.title, "Hello")
        XCTAssertEqual(index.note(forRelativePath: "b.md")?.title, "b")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MetadataIndexTests`
Expected: FAIL — `cannot find 'MetadataIndex' in scope`.

- [ ] **Step 3: Write minimal implementation** `Sources/VaultKit/MetadataIndex.swift`

```swift
import Foundation
import MarkdownCore

public struct NoteMeta: Equatable {
    public let path: String     // relative to vault root
    public let title: String
    public let mtime: Date
}

public struct MetadataIndex {
    public private(set) var notes: [NoteMeta]
    public init(notes: [NoteMeta] = []) { self.notes = notes }

    /// Build an index by reading each file's title (first H1, else filename).
    public static func build(from vault: Vault) throws -> MetadataIndex {
        let fm = FileManager.default
        var metas: [NoteMeta] = []
        for f in try vault.markdownFiles() {
            let text = (try? vault.read(f)) ?? ""
            let fallback = f.url.deletingPathExtension().lastPathComponent
            let title = TitleExtractor.title(fromMarkdown: text, fallback: fallback)
            let attrs = try? fm.attributesOfItem(atPath: f.url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            metas.append(NoteMeta(path: relativePath(of: f.url, under: vault.root),
                                  title: title, mtime: mtime))
        }
        return MetadataIndex(notes: metas)
    }

    public func note(forRelativePath path: String) -> NoteMeta? {
        notes.first { $0.path == path }
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
        return url.lastPathComponent
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MetadataIndexTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(vault): in-memory MetadataIndex with title extraction"
```

---

## Task 5: ExtensionSDK — public plugin protocols

No unit test (pure protocol declarations); verified by compilation and by Task 7's loop test.

**Files:**
- Create: `Sources/ExtensionSDK/ExtensionSDK.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add target to `Package.swift`**

Add to the `targets:` array:

```swift
        .target(name: "ExtensionSDK"),
```

- [ ] **Step 2: Write the protocols** `Sources/ExtensionSDK/ExtensionSDK.swift`

```swift
import SwiftUI
import Combine

/// A view a plugin contributes to the right sidebar.
public struct SidebarContribution: Identifiable {
    public let id: String
    public let title: String
    public let makeView: () -> AnyView
    public init(id: String, title: String, makeView: @escaping () -> AnyView) {
        self.id = id
        self.title = title
        self.makeView = makeView
    }
}

/// Surface ③ (UI): where plugins register sidebar views.
public protocol UIRegistry: AnyObject {
    func addSidebarView(id: String, title: String, _ make: @escaping () -> AnyView)
}

/// Read-only access to the active editor document.
public protocol EditorContext {
    /// Emits the current document text and every subsequent change.
    var activeText: AnyPublisher<String, Never> { get }
}

/// Capabilities handed to a plugin at activation (M0 subset of PluginHost).
public protocol PluginHost: AnyObject {
    var ui: UIRegistry { get }
    var editor: EditorContext { get }
}

/// A compile-time-loaded extension.
public protocol Plugin {
    static var id: String { get }
    init()
    func activate(host: PluginHost)
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(sdk): plugin host, UI registry, editor context protocols"
```

---

## Task 6: AppCore — AppState (vault open / open note / save)

**Files:**
- Create: `Sources/AppCore/AppState.swift`
- Test: `Tests/AppCoreTests/AppStateTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add targets to `Package.swift`**

Add to the `targets:` array:

```swift
        .target(name: "AppCore", dependencies: ["VaultKit", "ExtensionSDK"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "ExtensionSDK"]),
```

- [ ] **Step 2: Write the failing test** `Tests/AppCoreTests/AppStateTests.swift`

```swift
import XCTest
@testable import AppCore

final class AppStateTests: XCTestCase {
    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hanji-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_openVault_loadsFilesAndIndex() throws {
        let root = try makeTempDir("appstate")
        defer { try? FileManager.default.removeItem(at: root) }
        try "# A\nx".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let state = AppState()
        state.openVault(at: root)

        XCTAssertEqual(state.files.count, 1)
        XCTAssertEqual(state.index.notes.first?.title, "A")
    }

    func test_open_setsActiveText_and_save_persists() throws {
        let root = try makeTempDir("appstate2")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.md")
        try "hello".write(to: url, atomically: true, encoding: .utf8)

        let state = AppState()
        state.openVault(at: root)
        state.open(state.files[0])
        XCTAssertEqual(state.activeText, "hello")

        state.activeText = "changed"
        state.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "changed")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter AppStateTests`
Expected: FAIL — `cannot find 'AppState' in scope`.

- [ ] **Step 4: Write minimal implementation** `Sources/AppCore/AppState.swift`

```swift
import Foundation
import Combine
import VaultKit

public final class AppState: ObservableObject {
    @Published public var vaultRoot: URL?
    @Published public var files: [MarkdownFile] = []
    @Published public var selectedFile: MarkdownFile?
    @Published public var activeText: String = ""
    @Published public var index: MetadataIndex = MetadataIndex()

    private var vault: Vault?

    public init() {}

    public func openVault(at root: URL) {
        let v = Vault(root: root)
        vault = v
        vaultRoot = root
        files = (try? v.markdownFiles()) ?? []
        index = (try? MetadataIndex.build(from: v)) ?? MetadataIndex()
        selectedFile = nil
        activeText = ""
    }

    public func open(_ file: MarkdownFile) {
        selectedFile = file
        activeText = (try? vault?.read(file)) ?? ""
    }

    public func save() {
        guard let file = selectedFile, let vault else { return }
        try? vault.write(activeText, to: file)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter AppStateTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(appcore): AppState vault open/edit/save"
```

---

## Task 7: AppCore — PluginManager + Host (the plugin loop)

**Files:**
- Create: `Sources/AppCore/PluginManager.swift`
- Create: `Sources/AppCore/Host.swift`
- Test: `Tests/AppCoreTests/PluginLoopTests.swift`

- [ ] **Step 1: Write the failing test** `Tests/AppCoreTests/PluginLoopTests.swift`

```swift
import XCTest
import SwiftUI
import ExtensionSDK
@testable import AppCore

private struct TestPlugin: Plugin {
    static let id = "test.plugin"
    init() {}
    func activate(host: PluginHost) {
        host.ui.addSidebarView(id: "test.sidebar", title: "Test") { AnyView(Text("hi")) }
    }
}

final class PluginLoopTests: XCTestCase {
    func test_activate_registersSidebarContribution() {
        let appState = AppState()
        let pm = PluginManager()
        let host = Host(appState: appState, pluginManager: pm)

        pm.activate([TestPlugin()], host: host)

        XCTAssertEqual(pm.sidebar.count, 1)
        XCTAssertEqual(pm.sidebar.first?.id, "test.sidebar")
        XCTAssertEqual(pm.sidebar.first?.title, "Test")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PluginLoopTests`
Expected: FAIL — `cannot find 'PluginManager'` / `'Host'` in scope.

- [ ] **Step 3: Write `PluginManager`** `Sources/AppCore/PluginManager.swift`

```swift
import Foundation
import ExtensionSDK

public final class PluginManager: ObservableObject {
    @Published public private(set) var sidebar: [SidebarContribution] = []
    public init() {}

    public func activate(_ plugins: [Plugin], host: PluginHost) {
        for plugin in plugins { plugin.activate(host: host) }
    }

    func addSidebar(_ contribution: SidebarContribution) {
        sidebar.append(contribution)
    }
}
```

- [ ] **Step 4: Write `Host`** `Sources/AppCore/Host.swift`

```swift
import SwiftUI
import Combine
import ExtensionSDK

/// Concrete host wiring AppState + PluginManager to the SDK surfaces.
public final class Host: PluginHost, UIRegistry, EditorContext {
    private let appState: AppState
    private let pluginManager: PluginManager

    public init(appState: AppState, pluginManager: PluginManager) {
        self.appState = appState
        self.pluginManager = pluginManager
    }

    // PluginHost
    public var ui: UIRegistry { self }
    public var editor: EditorContext { self }

    // UIRegistry
    public func addSidebarView(id: String, title: String, _ make: @escaping () -> AnyView) {
        pluginManager.addSidebar(SidebarContribution(id: id, title: title, makeView: make))
    }

    // EditorContext
    public var activeText: AnyPublisher<String, Never> {
        appState.$activeText.eraseToAnyPublisher()
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PluginLoopTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(appcore): PluginManager + Host plugin loop"
```

---

## Task 8: WordCountPlugin (first-party plugin, dogfoods the SDK)

**Files:**
- Create: `Sources/WordCountPlugin/WordCountPlugin.swift`
- Test: `Tests/WordCountPluginTests/WordCounterTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add targets to `Package.swift`**

Add to the `targets:` array:

```swift
        .target(name: "WordCountPlugin", dependencies: ["ExtensionSDK"]),
        .testTarget(name: "WordCountPluginTests", dependencies: ["WordCountPlugin"]),
```

- [ ] **Step 2: Write the failing test** `Tests/WordCountPluginTests/WordCounterTests.swift`

```swift
import XCTest
@testable import WordCountPlugin

final class WordCounterTests: XCTestCase {
    func test_words() {
        XCTAssertEqual(WordCounter.words(in: "hello world"), 2)
        XCTAssertEqual(WordCounter.words(in: ""), 0)
        XCTAssertEqual(WordCounter.words(in: "a\nb c"), 3)
    }
    func test_characters() {
        XCTAssertEqual(WordCounter.characters(in: "hello"), 5)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter WordCounterTests`
Expected: FAIL — `cannot find 'WordCounter' in scope`.

- [ ] **Step 4: Write the plugin** `Sources/WordCountPlugin/WordCountPlugin.swift`

```swift
import SwiftUI
import Combine
import ExtensionSDK

public enum WordCounter {
    public static func words(in text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }
    public static func characters(in text: String) -> Int {
        text.count
    }
}

public struct WordCountPlugin: Plugin {
    public static let id = "io.hanji.wordcount"
    public init() {}

    public func activate(host: PluginHost) {
        let textPublisher = host.editor.activeText
        host.ui.addSidebarView(id: "wordcount", title: "Word Count") {
            AnyView(WordCountView(textPublisher: textPublisher))
        }
    }
}

struct WordCountView: View {
    let textPublisher: AnyPublisher<String, Never>
    @State private var words = 0
    @State private var chars = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Words: \(words)")
            Text("Characters: \(chars)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(textPublisher) { text in
            words = WordCounter.words(in: text)
            chars = WordCounter.characters(in: text)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter WordCounterTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(plugin): WordCount sidebar plugin"
```

---

## Task 9: EditorEngine — MarkdownEditorView (TextKit 2 bridge)

No unit test (AppKit UI); verified by build + the manual smoke test in Task 10.

**Files:**
- Create: `Sources/EditorEngine/MarkdownEditorView.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add the EditorEngine target to `Package.swift`**

Add to the `targets:` array:

```swift
        .target(name: "EditorEngine"),
```

- [ ] **Step 2: Write the editor view** `Sources/EditorEngine/MarkdownEditorView.swift`

```swift
import SwiftUI
import AppKit

/// A plain (no Live Preview yet) markdown editing surface backed by
/// NSTextView on the TextKit 2 stack. Two-way bound to `text`.
public struct MarkdownEditorView: NSViewRepresentable {
    @Binding public var text: String
    public init(text: Binding<String>) { self._text = text }

    public func makeNSView(context: Context) -> NSScrollView {
        // `usingTextLayoutManager: true` opts into TextKit 2 (macOS 12+).
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        init(_ parent: MarkdownEditorView) { self.parent = parent }
        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
```

- [ ] **Step 3: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(editor): TextKit 2 NSTextView editing surface"
```

---

## Task 10: HanjiApp — wire 3-pane UI + register plugin

Replaces the Task 1 skeleton app with the real shell. Verified by build + manual smoke test.

**Files:**
- Modify (overwrite): `Sources/HanjiApp/HanjiApp.swift`
- Create: `Sources/HanjiApp/ContentView.swift`
- Modify: `Package.swift` (add dependencies to the `HanjiApp` executable target)

- [ ] **Step 1: Update the executable target deps in `Package.swift`**

Replace the `HanjiApp` target entry with:

```swift
        .executableTarget(name: "HanjiApp", dependencies: [
            "AppCore", "EditorEngine", "ExtensionSDK", "WordCountPlugin", "VaultKit"
        ]),
```

- [ ] **Step 2: Overwrite the app entry point** `Sources/HanjiApp/HanjiApp.swift`

```swift
import SwiftUI
import AppKit
import AppCore
import ExtensionSDK
import WordCountPlugin

@main
struct HanjiApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var pluginManager = PluginManager()
    @State private var activated = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(pluginManager)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    guard !activated else { return }
                    activated = true
                    let host = Host(appState: appState, pluginManager: pluginManager)
                    let plugins: [Plugin] = [WordCountPlugin()]   // compile-time loading (D5)
                    pluginManager.activate(plugins, host: host)
                }
        }
    }
}
```

- [ ] **Step 3: Write the 3-pane shell** `Sources/HanjiApp/ContentView.swift`

```swift
import SwiftUI
import AppKit
import AppCore
import EditorEngine
import VaultKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var pluginManager: PluginManager

    private var selection: Binding<MarkdownFile.ID?> {
        Binding(
            get: { appState.selectedFile?.id },
            set: { id in
                if let file = appState.files.first(where: { $0.id == id }) {
                    appState.open(file)
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(appState.files, selection: selection) { file in
                Text(file.name)
            }
            .navigationTitle(appState.vaultRoot?.lastPathComponent ?? "Hanji")
            .toolbar {
                ToolbarItem {
                    Button(action: openVault) { Image(systemName: "folder") }
                        .help("Open vault folder")
                }
            }
        } content: {
            if appState.selectedFile != nil {
                MarkdownEditorView(text: $appState.activeText)
                    .toolbar {
                        ToolbarItem { Button("Save", action: appState.save) }
                    }
            } else {
                Text("Open a vault, then select a note")
                    .foregroundStyle(.secondary)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(pluginManager.sidebar) { contribution in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(contribution.title).font(.headline)
                            contribution.makeView()
                        }
                    }
                    if pluginManager.sidebar.isEmpty {
                        Text("No plugins").foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .frame(minWidth: 220)
        }
    }

    private func openVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.openVault(at: url)
        }
    }
}
```

- [ ] **Step 4: Build and run the full app**

Run: `swift build` (Expected: `Build complete!`), then `swift run hanji`.

- [ ] **Step 5: Manual smoke test (record results in the commit)**

Verify in the running app:
1. Window opens with three panes; right pane shows **"Word Count"** with `Words: 0` / `Characters: 0`.
2. Click the folder toolbar button → pick a folder containing `.md` files → the left list populates.
3. Select a note → its text loads in the center editor.
4. Type into the editor → the right-pane Word/Character counts update live (proves plugin ⟷ editor data flow).
5. Click **Save** → reopen the file (or check on disk) to confirm the change persisted.

Expected: all five behaviors work. If any fails, fix before committing.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(app): 3-pane shell, editor + word-count plugin wired"
```

---

## Task 11: `.app` bundle script (de-risks R2b)

**Files:**
- Create: `Scripts/bundle-app.sh`

- [ ] **Step 1: Write the bundling script** `Scripts/bundle-app.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="hanji"
CONFIG="release"

swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

APP="${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>hanji</string>
  <key>CFBundleIdentifier</key><string>io.hanji.app</string>
  <key>CFBundleVersion</key><string>0.0.1</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleExecutable</key><string>hanji</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Built ./$APP"
```

- [ ] **Step 2: Make it executable and run it**

```bash
chmod +x Scripts/bundle-app.sh
./Scripts/bundle-app.sh
```

Expected: prints `Built ./hanji.app`, and `hanji.app` exists at the project root.

- [ ] **Step 3: Launch the bundle**

Run: `open hanji.app`
Expected: the app launches with a proper Dock icon and window (this is the R2b deliverable: a launchable `.app` from a pure SPM build).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "build: script to assemble launchable .app bundle"
```

---

## Task 12: README + final verification

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# hanji

A native macOS (SwiftUI + TextKit 2) markdown editor that opens markdown vaults,
with a Swift extension SDK. See `docs/superpowers/specs/2026-06-06-native-markdown-editor-design.md`.

## Status: M0 — walking skeleton

- Opens a vault folder, lists `.md` files
- Edit + atomic save in a TextKit 2 editor
- In-memory metadata index (titles)
- Compile-time plugin SDK + bundled Word Count plugin

## Build & run

    swift run Checks     # run unit checks
    swift run hanji  # run from SPM
    ./Scripts/bundle-app.sh && open hanji.app  # build a .app bundle

Requires the Swift toolchain (Command Line Tools is sufficient; full Xcode optional).

## License

MIT
```

- [ ] **Step 2: Run the full check suite**

Run: `swift run Checks`
Expected: `✅ All checks passed` covering groups TitleExtractor, Vault, MetadataIndex, AppState, PluginLoop, WordCounter — no failures.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: README for M0 skeleton"
```

---

## Self-Review

**Spec coverage (M0 in spec §10):**
- "SPM 워크스페이스 + 모듈 스켈레톤" → Tasks 1–10 build all 7 targets (MarkdownCore, VaultKit, ExtensionSDK, EditorEngine, AppCore, WordCountPlugin, HanjiApp). ✓
- "보관함 열기 + 파일트리" → Task 6 (`openVault`) + Task 10 (file list / NSOpenPanel). ✓
- "(Live Preview 없는) 일반 NSTextView로 열기/저장" → Task 9 (editor) + Task 6 (`open`/`save`) + Task 10 (Save button). ✓
- "MetadataIndex 기본 빌드" → Task 4 (in-memory; GRDB persistence intentionally deferred to M3 per plan intro). ✓ (documented deviation)
- "ExtensionSDK 프로토콜 정의" → Task 5. ✓
- "'단어 수 세기' 사이드바 플러그인 1개로 호스트↔플러그인 루프 검증" → Task 7 (loop test) + Task 8 (plugin) + Task 10 step 5.4 (live update smoke). ✓
- "실행되는 .app 산출(SPM 빌드 경로 확정)" → Task 1 (build spike / R2), Task 11 (.app bundle / R2b). ✓

**Placeholder scan:** No "TBD"/"add error handling"/uncoded steps remain. Every code step shows complete code. ✓

**Type consistency:** `MarkdownFile`, `Vault`, `MetadataIndex`/`NoteMeta`, `AppState` (`openVault`/`open`/`save`/`activeText`/`files`/`index`/`selectedFile`), `PluginManager` (`activate`/`sidebar`/`addSidebar`), `Host(appState:pluginManager:)`, `SidebarContribution(id:title:makeView:)`, `UIRegistry.addSidebarView(id:title:_:)`, `EditorContext.activeText`, `Plugin` (`id`/`init`/`activate`), `WordCounter.words(in:)`/`characters(in:)`, `MarkdownEditorView(text:)` — names match across all tasks. ✓

**Risks validated by this plan:** R2 (Task 1), R2b (Task 11), TextKit bridge (Tasks 9–10), plugin loop (Tasks 7–8, 10). The hard Live Preview marker-hiding work (R1) is **not** in M0 — it starts in M1.
