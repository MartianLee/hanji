# hanji — Periodic Notes + Templater (+ ⌘P/⌘O palettes)

Design doc · 2026-06-09 · builds on [`2026-06-06-native-markdown-editor-design.md`](2026-06-06-native-markdown-editor-design.md)

## 1. Goal

Ship hanji's first two first-party plugins — **Periodic Notes** (daily/weekly/monthly) and **Templater** (curated `tp.*`, static substitution, no JS) — by dogfooding the extension SDK. This requires two new SDK surfaces (③ commands, a workspace note create/open capability) and two shell palettes: **⌘P** (command palette, the trigger for plugin commands) and **⌘O** (quick switcher, fuzzy file-name jump). It also fixes a first-run gap: today the only way to open a vault is a tiny folder icon in the file-list toolbar, so this milestone adds a **welcome / vault-selection onboarding** flow with recent-vault memory.

### Decisions (locked)

- **D-config:** Read the user's existing Obsidian config — `.obsidian/plugins/periodic-notes/data.json` (fallback `.obsidian/daily-notes.json`, then built-in defaults) for periodic settings, and `.obsidian/plugins/templater-obsidian/data.json` for the templates folder. Templates use Obsidian **Templater `<% tp.* %>`** syntax so the user's existing templates work unchanged. (Honors D1 vault compatibility.)
- **D-scope:** Periodic kinds = **daily + weekly + monthly** (quarterly/yearly deferred, same code path).
- **D-tp:** `tp.*` coverage = **core date + file**: `tp.date.now`, `tp.date.tomorrow`, `tp.date.yesterday`, `tp.file.title`, `tp.file.creation_date`, `tp.file.cursor`. All static substitution; `<%* … %>` execution blocks are stripped; unknown calls render empty.
- **D-arch:** **Approach A** — a pure, dependency-free `TemplateKit` library holds the engine, `tp.*` functions, moment-format→date formatting, Obsidian-config parsing, and the periodic open/create *planning*. Plugins are thin SDK adapters. Maximizes coverage by the headless `swift run Checks` runner.
- **D-palettes:** Build **both** ⌘P (command palette) and ⌘O (quick switcher) now — sibling overlay UIs sharing one component.
- **D-onboarding:** Replace the bare empty state with a **WelcomeView** (prominent "Open Vault…" + recent vaults), persist recent vaults, **auto-reopen the last vault on launch**, and add a minimal **Settings (⌘,)** window to manage recents.

Deferred (roadmap, explicitly out of scope here): SDK ④ `TemplateRegistry`/`NoteLifecycle` surfaces (no consumer beyond first-party, which uses TemplateKit directly); quarterly/yearly periodic notes; mid-document "insert template at caret" (needs an editor mutation API); global FTS search; Calendar plugin.

## 2. Targets & dependency graph

```
TemplateKit (NEW, pure — Foundation only)
    engine + tp.* fns + MomentFormat + Obsidian config parse + periodic open/create planning
TemplaterPlugin     (NEW)  → ExtensionSDK, TemplateKit
PeriodicNotesPlugin (NEW)  → ExtensionSDK, TemplateKit
ExtensionSDK        (edit) +③ Command/CommandRegistry, +WorkspaceActions   (no new deps)
AppCore / Host      (edit) implements CommandRegistry + WorkspaceActions; AppState recent-vaults  (already deps ExtensionSDK, VaultKit)
HanjiApp        (edit) + register both plugins; ⌘P/⌘O palettes; WelcomeView + Settings(⌘,) onboarding
Checks              (edit) + TemplateKit groups (engine/format/config/planning — all pure)
```

No dependency cycles: `TemplateKit` depends on nothing in-repo; `ExtensionSDK` stays UI-surface-only; plugins depend on `ExtensionSDK` + `TemplateKit`; the host (`AppCore`) implements the SDK protocols.

## 3. SDK additions

```swift
// ③ Commands
public struct Command: Identifiable {
    public let id: String
    public let title: String
    public let run: () -> Void
    public init(id: String, title: String, run: @escaping () -> Void)
}
public protocol CommandRegistry: AnyObject { func register(_ command: Command) }

// Workspace note actions (consumed by both plugins)
public protocol WorkspaceActions: AnyObject {
    var vaultRoot: URL? { get }
    func noteExists(relativePath: String) -> Bool
    func readNote(relativePath: String) -> String?
    func createNote(relativePath: String, text: String, cursorOffset: Int?)
    func openNote(relativePath: String)
    func pickNote(title: String, startingFolder: String?) -> String?   // NSOpenPanel (Templater)
    func promptNewNotePath(suggestedName: String) -> String?           // NSSavePanel (Templater)
}

// PluginHost grows:
//   var commands: CommandRegistry { get }
//   var workspace: WorkspaceActions { get }
```

`Command.run` is a bare closure; the plugin captures `host` at `activate(host:)`, so no separate `CommandContext` is needed yet. Relative paths are vault-root-relative POSIX paths (e.g. `"Daily/2026-06-09.md"`).

## 4. Shell: ⌘P command palette + ⌘O quick switcher

- `PluginManager` gains `@Published var commands: [Command]`; `Host` implements `CommandRegistry` by appending. (Sidebar handling stays as-is.)
- One reusable SwiftUI overlay `PaletteView(items, onRun)`: a search field (autofocused), a filtered list with keyboard ↑/↓ selection and ⏎ to activate, Esc to dismiss. Simple case-insensitive subsequence ("fuzzy") match + rank by match position.
- `ContentView` hosts two palette states toggled by `.keyboardShortcut("p"/"o", modifiers: .command)`:
  - **⌘P** → items = `pluginManager.commands` (title), activate = `command.run()`.
  - **⌘O** → items = `appState.files` (name), activate = `appState.open(file)`.
- Palettes are mutually exclusive; opening one closes the other; Esc closes.

## 5. TemplateKit (pure core — every piece tested in `Checks`)

### 5.1 MomentFormat
`MomentFormat.format(_ date: Date, _ pattern: String, calendar:/locale: defaults) -> String`. Hand-rolled tokenizer over the pattern (not `DateFormatter` patterns — moment tokens and bracket-literals differ). Supported tokens:
`YYYY YY` · `MMMM MMM MM M` · `DD D` · `dddd ddd` · `HH mm ss` · `gggg ww` (ISO week-year / ISO week, via `Calendar(identifier: .iso8601)`) · `Q` · `[literal]` passes through verbatim. Unknown runs pass through literally.

### 5.2 TemplateEngine
`render(_ template: String, _ ctx: TemplateContext) -> RenderedTemplate` where `RenderedTemplate = (text: String, cursorOffset: Int?)`.
- Scans for `<% … %>` spans. `<%* … %>` (execution) spans are removed (out of scope).
- Inside a span, parse `namespace.function(args)` — `tp.` prefix optional; args are quoted strings or integers, comma-separated; trailing/leading whitespace tolerated.
- Resolve against the function table (5.3); unknown calls → `""`.
- `tp.file.cursor(order?)` is special: it contributes no text, but the engine records the UTF-16 offset of the **first** cursor token (lowest order) in the output; that becomes `cursorOffset`.

### 5.3 Template functions (`TemplateContext { now: Date; title: String; creationDate: Date }`)
- `tp.date.now(format="YYYY-MM-DD", offsetDays=0, reference?, referenceFormat?)` → `MomentFormat.format(now + offsetDays, format)`. (`reference` parsing is accepted but, if absent, uses `now`.)
- `tp.date.tomorrow(format="YYYY-MM-DD")` = now+1 day; `tp.date.yesterday(format="YYYY-MM-DD")` = now−1 day.
- `tp.file.title` → `ctx.title`.
- `tp.file.creation_date(format="YYYY-MM-DD HH:mm")` → format `ctx.creationDate`.
- `tp.file.cursor(order=0)` → cursor sentinel (see 5.2).

### 5.4 Periodic config + planning
- `enum PeriodicKind { case daily, weekly, monthly }`.
- `struct PeriodicSettings { let folder: String; let format: String; let template: String? }`.
- `struct PeriodicConfig { settings(for: PeriodicKind) -> PeriodicSettings }`.
- `PeriodicConfig.load(vaultRoot: URL) -> PeriodicConfig`: read `.obsidian/plugins/periodic-notes/data.json`; fall back per-kind to `.obsidian/daily-notes.json` (daily only) and then built-in defaults — `folder: ""`, formats `daily=YYYY-MM-DD`, `weekly=gggg-[W]ww`, `monthly=YYYY-MM`, no template. A `template` value missing the `.md` extension gets it appended.
- `func notePath(_ kind: PeriodicKind, date: Date) -> String` → `folder + "/" + MomentFormat.format(date, format) + ".md"` (no leading slash when folder is empty).
- `func templatePath(_ kind: PeriodicKind) -> String?`.
- Planning (pure, given closures so it's unit-testable with fakes):
```swift
enum OpenAction: Equatable {
    case open(path: String)
    case create(path: String, text: String, cursor: Int?)
}
func planOpen(_ kind: PeriodicKind, date: Date,
              exists: (String) -> Bool,
              readTemplate: (String) -> String?,
              now: Date) -> OpenAction
```
If the note exists → `.open`. Else render the kind's template (empty string if none) via `TemplateEngine` with `ctx.title` = the note's base filename → `.create(path, text, cursor)`.

### 5.5 Templater config
`TemplaterConfig.templatesFolder(vaultRoot:) -> String` reads `.obsidian/plugins/templater-obsidian/data.json` (`templates_folder`), default `"Templates"`.

## 6. Plugins

### 6.1 PeriodicNotesPlugin (default-on)
`activate(host:)` registers three static commands: **Open today's daily note**, **Open this week's note**, **Open this month's note**. Each `run`:
```swift
let cfg = PeriodicConfig.load(vaultRoot: host.workspace.vaultRoot!)
let action = cfg.planOpen(kind, date: Date(),
                          exists: { host.workspace.noteExists($0) },
                          readTemplate: { host.workspace.readNote($0) },
                          now: Date())
switch action {
case .open(let p): host.workspace.openNote(p)
case .create(let p, let text, let cursor):
    host.workspace.createNote(relativePath: p, text: text, cursorOffset: cursor)
    host.workspace.openNote(p)
}
```

### 6.2 TemplaterPlugin
`activate(host:)` registers one command **New note from template…**. `run`:
1. `let folder = TemplaterConfig.templatesFolder(vaultRoot:)`.
2. `host.workspace.pickNote(title: "Choose template", startingFolder: folder)` → template relative path (nil = cancel).
3. `host.workspace.promptNewNotePath(suggestedName:)` → new note relative path (nil = cancel).
4. Render the template via `TemplateEngine` (ctx.title = new note's base name) → `createNote` + `openNote` at cursor.

(Mid-document "insert at caret" deferred — needs an editor mutation API.)

## 7. Host wiring (AppCore)

- `Host` adds `CommandRegistry` (append to `PluginManager.commands`) and `WorkspaceActions`:
  - `createNote`: atomic write via `Vault` (creating intermediate folders), then refresh `appState.files`, select the new file, set `appState.pendingCursorOffset = cursorOffset`.
  - `openNote(relativePath:)`: resolve to a `MarkdownFile` (refresh list if unseen) and `appState.open(_:)`.
  - `pickNote` / `promptNewNotePath`: `NSOpenPanel` / `NSSavePanel` rooted at the vault (AppKit stays in the host, not the plugins).
- `AppState` gains `@Published var pendingCursorOffset: Int?`; `MarkdownEditorView` consumes it on load to set the caret (same hook style as the existing `HANJI_CARET`), clearing it after.

## 8. Onboarding & vault selection

Problem: the only entry point is a small folder icon in the file-list toolbar, and the empty state is a bare "Open a vault…" line — not discoverable. Add:

- **WelcomeView** (shown whenever `vaultRoot == nil`, replacing the bare text): a centered card — "Hanji", a one-line subtitle/hint ("Open a folder of `.md` files"), a prominent **Open Vault…** button (reuses the existing `NSOpenPanel` flow), and a **Recent vaults** list. Each recent row shows the folder name + dimmed path and reopens on click; a path that no longer exists is shown disabled with a "missing" hint. First run (no recents) shows just the button + hint.
- **Recent vaults persistence:** `AppState` persists up to 8 recent vault paths in `UserDefaults` (key `io.hanji.recentVaults`). `openVault(at:)` prepends + dedupes + caps. The app is not sandboxed, so plain paths suffice (no security-scoped bookmarks). `AppState.init(defaults: UserDefaults = .standard)` so the suite is injectable for tests.
- **Launch behavior** (HanjiApp): `HANJI_OPEN_VAULT` wins if set (test hook); else if the most-recent vault still exists, auto-reopen it; else show WelcomeView. (Obsidian-like "reopen last vault.")
- **Settings (⌘,):** a minimal `Settings` scene — current vault, the recent list with **Open…** / **Remove**, and **Clear recents**. Keeps recents manageable without a full settings system.

Wiring stays in the App shell + `AppState`; no new targets. `AppState` gains `@Published var recentVaults: [URL]` plus `removeRecent(_:)` / `clearRecents()`.

## 9. Testing

**Headless (`swift run Checks`), all pure:**
- `MomentFormat` — fixed dates → expected strings incl. ISO week (`gggg-[W]ww`) and `YYYY-MM`.
- `TemplateEngine` — templates with each `tp.*` token (fixed `now`) → expected text; `tp.file.cursor` offset; `<%* %>` stripped; unknown → empty.
- `PeriodicConfig` — write a sample `data.json` to a temp dir → expected folder/format/template; `notePath` for a fixed date; defaults when files absent.
- `PeriodicPlan` — `planOpen` with fake `exists`/`readTemplate` → `.open` when present, `.create` with rendered text+cursor when absent.
- `Recents` (in `AppStateChecks`) — `openVault` prepend/dedupe/cap-at-8 and persist→reload round-trip via an injected `UserDefaults(suiteName:)`; `removeRecent`/`clearRecents`.

**E2E (screenshot):** (a) seed the demo vault with `.obsidian/plugins/periodic-notes/data.json` + `Templates/Daily.md` (uses `<% tp.date.now %>`, `<% tp.file.title %>`, `<% tp.file.cursor %>`); launch, ⌘P → "Open today's daily note", confirm the created note opens with the template rendered and the caret at the cursor token. ⌘O → confirm fuzzy file jump. (b) Launch with no `HANJI_OPEN_VAULT` and a cleared defaults suite → WelcomeView with the **Open Vault…** button is visible; after opening, relaunch auto-reopens the same vault.

## 10. Out of scope / roadmap

SDK ④ `TemplateRegistry`/`NoteLifecycle`; quarterly/yearly periodic notes; insert-template-at-caret; Calendar plugin; global FTS search; a **full settings system** (this milestone adds only a minimal recents-management Settings window — plugin/editor preferences and editing the periodic/templater config from inside hanji remain roadmap; for now that config is read from Obsidian's files).
