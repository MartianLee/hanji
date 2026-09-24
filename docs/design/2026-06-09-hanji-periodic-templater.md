# Periodic Notes + Templater + ⌘P/⌘O + Onboarding — Implementation Plan

**Goal:** Ship hanji's first two first-party plugins — Periodic Notes (daily/weekly/monthly) and Templater (curated `tp.*`, static substitution) — plus the ⌘P command palette, ⌘O quick switcher, and a welcome/vault-selection onboarding flow.

**Architecture:** A pure, dependency-free `TemplateKit` library holds the template engine, `tp.*` functions, moment-format→date formatting, Obsidian-config parsing, and periodic open/create planning (fully tested via the headless `swift run Checks` runner). The extension SDK grows by exactly two surfaces actually consumed now — ③ `Command`/`CommandRegistry` and a `WorkspaceActions` note create/open capability — and the two plugins are thin adapters. The SwiftUI shell gains a reusable palette overlay (⌘P/⌘O) and a WelcomeView + Settings window backed by recent-vault persistence in `AppState`.

**Tech Stack:** Swift 5.10 / SPM, SwiftUI + AppKit + TextKit 2, Foundation `JSONSerialization`, custom `Checks` test runner (XCTest unavailable with Command Line Tools only). Build/test: `swift build`, `swift run Checks [Group]`, `./Scripts/bundle-app.sh`.

**Spec:** `docs/design/2026-06-09-hanji-periodic-templater-design.md`

**Conventions for every task:**
- Tests are functions in `Sources/Checks/<Name>Checks.swift` using `expect(_:_:)` / `expectEqual(_:_:_:)`, registered as a tuple in `Sources/Checks/main.swift`.
- The "red" step for a brand-new symbol is a **build failure** (`cannot find 'X' in scope`) because Swift compiles the whole `Checks` target; that is the expected failing state. After implementing, the same command turns green.
- Commit after each task. Branch is `periodic-templater` (already created).

---

## File structure

**New library `TemplateKit` (pure, Foundation only):**
- `Sources/TemplateKit/MomentFormat.swift` — moment-token date formatting.
- `Sources/TemplateKit/TemplateEngine.swift` — `<% tp.* %>` parse/render + `TemplateContext`, `RenderedTemplate`, `tp.*` functions, cursor token.
- `Sources/TemplateKit/PeriodicConfig.swift` — `PeriodicKind`, `PeriodicSettings`, `PeriodicConfig` (load/parse, `notePath`, `templatePath`), `OpenAction`, `planOpen`.
- `Sources/TemplateKit/TemplaterConfig.swift` — `templatesFolder`.

**New plugin targets (thin adapters):**
- `Sources/PeriodicNotesPlugin/PeriodicNotesPlugin.swift`
- `Sources/TemplaterPlugin/TemplaterPlugin.swift`

**Modified:**
- `Sources/MarkdownCore/FuzzyFilter.swift` (new, pure) — palette fuzzy match/sort.
- `Sources/ExtensionSDK/ExtensionSDK.swift` — `Command`, `CommandRegistry`, `WorkspaceActions`; extend `PluginHost`.
- `Sources/AppCore/AppState.swift` — recent vaults, file ops, `pendingCursorOffset`.
- `Sources/AppCore/PluginManager.swift` — `commands`.
- `Sources/AppCore/Host.swift` — `CommandRegistry` + `WorkspaceActions` conformance.
- `Sources/EditorEngine/MarkdownEditorView.swift` — consume `pendingCursorOffset`.
- `Sources/HanjiApp/HanjiApp.swift` — register plugins; launch auto-reopen; Settings scene; ⌘P/⌘O menu commands.
- `Sources/HanjiApp/ContentView.swift` — Welcome vs split view; palette overlay.
- `Sources/HanjiApp/UIState.swift` (new), `PaletteView.swift` (new), `WelcomeView.swift` (new), `SettingsView.swift` (new).
- `Package.swift`, `Scripts/bundle-app.sh`, `README.md`.
- `Sources/Checks/*` + `Sources/Checks/main.swift`.

---

## Task 1: TemplateKit target + MomentFormat

**Files:**
- Create: `Sources/TemplateKit/MomentFormat.swift`
- Modify: `Package.swift`
- Create: `Sources/Checks/MomentFormatChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Add the target and wire deps in `Package.swift`**

Add to the `targets:` array (after the `ExtensionSDK` line):
```swift
        .target(name: "TemplateKit"),
```
Change the `Checks` target line to include `TemplateKit`:
```swift
        .executableTarget(name: "Checks", dependencies: ["MarkdownCore", "VaultKit", "AppCore", "ExtensionSDK", "WordCountPlugin", "EditorEngine", "TemplateKit"]),
```

- [ ] **Step 2: Write the failing test** — `Sources/Checks/MomentFormatChecks.swift`

```swift
import Foundation
import TemplateKit

func momentFormatChecks() {
    let utc = TimeZone(identifier: "UTC")!
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        return cal.date(from: c)!
    }
    let d = date(2026, 6, 9, 14, 5, 7)            // 2026-06-09 is a Tuesday
    expectEqual(MomentFormat.format(d, "YYYY-MM-DD", timeZone: utc), "2026-06-09", "daily format")
    expectEqual(MomentFormat.format(d, "YYYY-MM", timeZone: utc), "2026-06", "monthly format")
    expectEqual(MomentFormat.format(d, "YYYY-MM-DD HH:mm", timeZone: utc), "2026-06-09 14:05", "date+time")
    expectEqual(MomentFormat.format(d, "ddd, MMM D", timeZone: utc), "Tue, Jun 9", "weekday+month names")
    let jan1 = date(2026, 1, 1)                   // Thursday → ISO week 1 of 2026
    expectEqual(MomentFormat.format(jan1, "gggg-[W]ww", timeZone: utc), "2026-W01", "ISO week with literal")
    expectEqual(MomentFormat.format(d, "[Q]Q", timeZone: utc), "Q2", "quarter with literal")
}
```

- [ ] **Step 3: Register the group in `Sources/Checks/main.swift`**

Add `("MomentFormat", momentFormatChecks),` to the array passed to `runChecks`.

- [ ] **Step 4: Run to verify it fails**

Run: `swift run Checks MomentFormat`
Expected: build failure — `cannot find 'MomentFormat' in scope`.

- [ ] **Step 5: Implement `Sources/TemplateKit/MomentFormat.swift`**

```swift
import Foundation

/// Formats a `Date` using a subset of moment.js tokens. Text inside `[...]` is literal.
/// Supported: YYYY YY · MMMM MMM MM M · DD D · dddd ddd · HH mm ss · gggg ww (ISO) · Q.
public enum MomentFormat {
    public static func format(_ date: Date, _ pattern: String,
                              timeZone: TimeZone = .current,
                              locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone; cal.locale = locale
        var iso = Calendar(identifier: .iso8601); iso.timeZone = timeZone; iso.locale = locale
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let isoYear = iso.component(.yearForWeekOfYear, from: date)
        let isoWeek = iso.component(.weekOfYear, from: date)
        let quarter = (c.month! - 1) / 3 + 1
        let months = ["January","February","March","April","May","June",
                      "July","August","September","October","November","December"]
        let weekdays = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"] // weekday 1 = Sunday
        func pad(_ n: Int, _ w: Int) -> String { String(format: "%0\(w)d", n) }

        // Longest-first so YYYY matches before YY, MMMM before MMM, etc.
        let tokens: [(String, () -> String)] = [
            ("YYYY", { pad(c.year!, 4) }), ("YY", { pad(c.year! % 100, 2) }),
            ("MMMM", { months[c.month! - 1] }), ("MMM", { String(months[c.month! - 1].prefix(3)) }),
            ("MM", { pad(c.month!, 2) }), ("M", { String(c.month!) }),
            ("DD", { pad(c.day!, 2) }), ("D", { String(c.day!) }),
            ("dddd", { weekdays[c.weekday! - 1] }), ("ddd", { String(weekdays[c.weekday! - 1].prefix(3)) }),
            ("HH", { pad(c.hour!, 2) }), ("mm", { pad(c.minute!, 2) }), ("ss", { pad(c.second!, 2) }),
            ("gggg", { pad(isoYear, 4) }), ("ww", { pad(isoWeek, 2) }),
            ("Q", { String(quarter) }),
        ]
        let chars = Array(pattern)
        var out = ""
        var i = 0
        outer: while i < chars.count {
            if chars[i] == "[" {
                var j = i + 1
                while j < chars.count && chars[j] != "]" { out.append(chars[j]); j += 1 }
                i = (j < chars.count) ? j + 1 : j
                continue
            }
            for (tok, make) in tokens where matches(chars, i, tok) {
                out += make(); i += tok.count; continue outer
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    private static func matches(_ chars: [Character], _ i: Int, _ tok: String) -> Bool {
        let t = Array(tok)
        guard i + t.count <= chars.count else { return false }
        for k in 0..<t.count where chars[i + k] != t[k] { return false }
        return true
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `swift run Checks MomentFormat`
Expected: `✅ All checks passed (... assertions, 1 group(s))`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/TemplateKit/MomentFormat.swift Sources/Checks/MomentFormatChecks.swift Sources/Checks/main.swift
git commit -m "feat(templatekit): MomentFormat date formatting + target"
```

---

## Task 2: TemplateEngine + tp.* functions + cursor

**Files:**
- Create: `Sources/TemplateKit/TemplateEngine.swift`
- Create: `Sources/Checks/TemplateEngineChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — `Sources/Checks/TemplateEngineChecks.swift`

```swift
import Foundation
import TemplateKit

func templateEngineChecks() {
    let utc = TimeZone(identifier: "UTC")!
    var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 9
    var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
    let now = cal.date(from: c)!
    let ctx = TemplateContext(now: now, title: "My Note", creationDate: now, timeZone: utc)

    expectEqual(TemplateEngine.render("# <% tp.date.now(\"YYYY-MM-DD\") %>", ctx).text,
                "# 2026-06-09", "tp.date.now with format")
    expectEqual(TemplateEngine.render("<% tp.date.tomorrow(\"YYYY-MM-DD\") %>", ctx).text,
                "2026-06-10", "tp.date.tomorrow")
    expectEqual(TemplateEngine.render("<% tp.date.yesterday(\"YYYY-MM-DD\") %>", ctx).text,
                "2026-06-08", "tp.date.yesterday")
    expectEqual(TemplateEngine.render("<% tp.date.now(\"YYYY-MM-DD\", -2) %>", ctx).text,
                "2026-06-07", "tp.date.now with offset")
    expectEqual(TemplateEngine.render("Title: <% tp.file.title %>", ctx).text,
                "Title: My Note", "tp.file.title (no parens)")
    expectEqual(TemplateEngine.render("<% tp.unknown.fn() %>!", ctx).text, "!", "unknown call → empty")
    expectEqual(TemplateEngine.render("a<%* tp.whatever() %>b", ctx).text, "ab", "exec block stripped")

    let cursor = TemplateEngine.render("AB<% tp.file.cursor() %>CD", ctx)
    expectEqual(cursor.text, "ABCD", "cursor token removed from text")
    expectEqual(cursor.cursorOffset, 2, "cursor offset recorded (UTF-16)")
    expect(TemplateEngine.render("no cursor", ctx).cursorOffset == nil, "no cursor → nil offset")
}
```

- [ ] **Step 2: Register the group**

Add `("TemplateEngine", templateEngineChecks),` to `main.swift`.

- [ ] **Step 3: Run to verify it fails**

Run: `swift run Checks TemplateEngine`
Expected: build failure — `cannot find 'TemplateEngine' / 'TemplateContext' in scope`.

- [ ] **Step 4: Implement `Sources/TemplateKit/TemplateEngine.swift`**

```swift
import Foundation

public struct TemplateContext {
    public var now: Date
    public var title: String
    public var creationDate: Date
    public var timeZone: TimeZone
    public init(now: Date = Date(), title: String, creationDate: Date = Date(), timeZone: TimeZone = .current) {
        self.now = now; self.title = title; self.creationDate = creationDate; self.timeZone = timeZone
    }
}

public struct RenderedTemplate: Equatable {
    public let text: String
    public let cursorOffset: Int?
    public init(text: String, cursorOffset: Int?) { self.text = text; self.cursorOffset = cursorOffset }
}

public enum TemplateEngine {
    public static func render(_ template: String, _ ctx: TemplateContext) -> RenderedTemplate {
        let s = Array(template)
        var out = ""
        var cursor: (order: Int, offset: Int)? = nil
        var i = 0
        while i < s.count {
            if s[i] == "<", i + 1 < s.count, s[i + 1] == "%" {
                let isExec = (i + 2 < s.count && s[i + 2] == "*")
                var j = i + 2
                while j + 1 < s.count && !(s[j] == "%" && s[j + 1] == ">") { j += 1 }
                let inner = String(s[(i + 2)..<min(j, s.count)])
                let end = (j + 1 < s.count) ? j + 2 : s.count
                if !isExec, let call = parseCall(inner) {
                    if call.namespace == "tp", call.function == "file.cursor" {
                        let order = call.intArg(0) ?? 0
                        if cursor == nil || order < cursor!.order { cursor = (order, out.utf16.count) }
                    } else {
                        out += evaluate(call, ctx)
                    }
                }
                i = end
            } else {
                out.append(s[i]); i += 1
            }
        }
        return RenderedTemplate(text: out, cursorOffset: cursor?.offset)
    }

    // MARK: - Parsing

    private enum Arg { case string(String), int(Int)
        var asString: String? { if case .string(let v) = self { return v }; return nil }
        var asInt: Int? { if case .int(let v) = self { return v }; return nil }
    }
    private struct Call {
        let namespace: String   // e.g. "tp"
        let function: String    // e.g. "date.now", "file.title"
        let args: [Arg]
        func stringArg(_ i: Int) -> String? { i < args.count ? args[i].asString : nil }
        func intArg(_ i: Int) -> Int? { i < args.count ? args[i].asInt : nil }
    }

    private static func parseCall(_ raw: String) -> Call? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var head = trimmed
        var argsPart = ""
        if let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close {
            head = String(trimmed[trimmed.startIndex..<open])
            argsPart = String(trimmed[trimmed.index(after: open)..<close])
        }
        let dotted = head.split(separator: ".", maxSplits: 1).map(String.init)
        guard dotted.count == 2 else { return nil }
        return Call(namespace: dotted[0], function: dotted[1], args: parseArgs(argsPart))
    }

    private static func parseArgs(_ s: String) -> [Arg] {
        var args: [Arg] = []
        var fields: [String] = []
        var cur = ""
        var inQuote = false
        for ch in s {
            if ch == "\"" { inQuote.toggle(); cur.append(ch) }
            else if ch == "," && !inQuote { fields.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty || !fields.isEmpty { fields.append(cur) }
        for f in fields {
            let t = f.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
                args.append(.string(String(t.dropFirst().dropLast())))
            } else if let n = Int(t) {
                args.append(.int(n))
            }
        }
        return args
    }

    // MARK: - Evaluation

    private static func evaluate(_ call: Call, _ ctx: TemplateContext) -> String {
        func addDays(_ d: Date, _ n: Int) -> Date {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = ctx.timeZone
            return cal.date(byAdding: .day, value: n, to: d) ?? d
        }
        switch call.function {
        case "date.now":
            return MomentFormat.format(addDays(ctx.now, call.intArg(1) ?? 0),
                                       call.stringArg(0) ?? "YYYY-MM-DD", timeZone: ctx.timeZone)
        case "date.tomorrow":
            return MomentFormat.format(addDays(ctx.now, 1), call.stringArg(0) ?? "YYYY-MM-DD", timeZone: ctx.timeZone)
        case "date.yesterday":
            return MomentFormat.format(addDays(ctx.now, -1), call.stringArg(0) ?? "YYYY-MM-DD", timeZone: ctx.timeZone)
        case "file.title":
            return ctx.title
        case "file.creation_date":
            return MomentFormat.format(ctx.creationDate, call.stringArg(0) ?? "YYYY-MM-DD HH:mm", timeZone: ctx.timeZone)
        default:
            return ""
        }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run Checks TemplateEngine`
Expected: `✅ All checks passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/TemplateKit/TemplateEngine.swift Sources/Checks/TemplateEngineChecks.swift Sources/Checks/main.swift
git commit -m "feat(templatekit): TemplateEngine + tp.* functions + cursor token"
```

---

## Task 3: PeriodicConfig (parse + notePath)

**Files:**
- Create: `Sources/TemplateKit/PeriodicConfig.swift`
- Create: `Sources/Checks/PeriodicConfigChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — `Sources/Checks/PeriodicConfigChecks.swift`

```swift
import Foundation
import TemplateKit

func periodicConfigChecks() {
    let utc = TimeZone(identifier: "UTC")!
    var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 9
    var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
    let d = cal.date(from: c)!

    // Defaults when no .obsidian config present.
    let fm = FileManager.default
    let empty = fm.temporaryDirectory.appendingPathComponent("mk-pc-empty-\(UUID().uuidString)")
    try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: empty) }
    let defcfg = PeriodicConfig.load(vaultRoot: empty)
    expectEqual(defcfg.notePath(.daily, date: d, timeZone: utc), "2026-06-09.md", "default daily path (root)")
    expectEqual(defcfg.notePath(.weekly, date: d, timeZone: utc), "2026-W24.md", "default weekly path")
    expectEqual(defcfg.notePath(.monthly, date: d, timeZone: utc), "2026-06.md", "default monthly path")
    expect(defcfg.templatePath(.daily) == nil, "no template by default")

    // Reading an Obsidian periodic-notes data.json.
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-pc-\(UUID().uuidString)")
    let pluginDir = vault.appendingPathComponent(".obsidian/plugins/periodic-notes")
    try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    let json = """
    { "daily":   { "folder": "Daily",   "format": "YYYY-MM-DD", "template": "Templates/Daily" },
      "monthly": { "folder": "Journal/Monthly", "format": "YYYY-MM", "template": "Templates/Monthly.md" } }
    """
    try? json.write(to: pluginDir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    let cfg = PeriodicConfig.load(vaultRoot: vault)
    expectEqual(cfg.notePath(.daily, date: d, timeZone: utc), "Daily/2026-06-09.md", "configured daily path")
    expectEqual(cfg.templatePath(.daily), "Templates/Daily.md", "template gets .md appended")
    expectEqual(cfg.notePath(.monthly, date: d, timeZone: utc), "Journal/Monthly/2026-06.md", "configured monthly path")
    expectEqual(cfg.templatePath(.monthly), "Templates/Monthly.md", "template kept as-is when .md present")
    expectEqual(cfg.notePath(.weekly, date: d, timeZone: utc), "2026-W24.md", "weekly falls back to default")
}
```

(2026-06-09 is in ISO week 24.)

- [ ] **Step 2: Register the group**

Add `("PeriodicConfig", periodicConfigChecks),` to `main.swift`.

- [ ] **Step 3: Run to verify it fails**

Run: `swift run Checks PeriodicConfig`
Expected: build failure — `cannot find 'PeriodicConfig' in scope`.

- [ ] **Step 4: Implement `Sources/TemplateKit/PeriodicConfig.swift`**

```swift
import Foundation

public enum PeriodicKind: String, CaseIterable { case daily, weekly, monthly }

public struct PeriodicSettings: Equatable {
    public let folder: String
    public let format: String
    public let template: String?    // vault-relative path ending in .md, or nil
    public init(folder: String, format: String, template: String?) {
        self.folder = folder; self.format = format; self.template = template
    }
}

public struct PeriodicConfig {
    private let map: [PeriodicKind: PeriodicSettings]
    public init(_ map: [PeriodicKind: PeriodicSettings]) { self.map = map }

    public func settings(for kind: PeriodicKind) -> PeriodicSettings { map[kind] ?? PeriodicConfig.defaults(kind) }

    public static func defaults(_ kind: PeriodicKind) -> PeriodicSettings {
        switch kind {
        case .daily:   return PeriodicSettings(folder: "", format: "YYYY-MM-DD", template: nil)
        case .weekly:  return PeriodicSettings(folder: "", format: "gggg-[W]ww", template: nil)
        case .monthly: return PeriodicSettings(folder: "", format: "YYYY-MM", template: nil)
        }
    }

    public func notePath(_ kind: PeriodicKind, date: Date, timeZone: TimeZone = .current) -> String {
        let s = settings(for: kind)
        let name = MomentFormat.format(date, s.format, timeZone: timeZone) + ".md"
        return s.folder.isEmpty ? name : s.folder + "/" + name
    }

    public func templatePath(_ kind: PeriodicKind) -> String? { settings(for: kind).template }

    // MARK: - Loading

    public static func load(vaultRoot: URL) -> PeriodicConfig {
        let periodic = vaultRoot.appendingPathComponent(".obsidian/plugins/periodic-notes/data.json")
        if let obj = readJSONObject(periodic) { return parse(obj) }
        // Fallback: core daily-notes.json (daily only).
        let daily = vaultRoot.appendingPathComponent(".obsidian/daily-notes.json")
        if let obj = readJSONObject(daily), let s = settings(from: obj) {
            return PeriodicConfig([.daily: s])
        }
        return PeriodicConfig([:])
    }

    static func parse(_ obj: [String: Any]) -> PeriodicConfig {
        var map: [PeriodicKind: PeriodicSettings] = [:]
        for kind in PeriodicKind.allCases {
            if let sub = obj[kind.rawValue] as? [String: Any], let s = settings(from: sub) { map[kind] = s }
        }
        return PeriodicConfig(map)
    }

    static func settings(from obj: [String: Any]) -> PeriodicSettings? {
        let folder = (obj["folder"] as? String) ?? ""
        let format = (obj["format"] as? String) ?? ""
        guard !format.isEmpty else { return nil }
        var template: String? = nil
        if let t = obj["template"] as? String, !t.isEmpty {
            template = t.lowercased().hasSuffix(".md") ? t : t + ".md"
        }
        return PeriodicSettings(folder: folder, format: format, template: template)
    }

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run Checks PeriodicConfig`
Expected: `✅ All checks passed`. (If weekly path differs, confirm 2026-06-09 ISO week with `MomentFormat`; adjust only the test's expected string, never the impl.)

- [ ] **Step 6: Commit**

```bash
git add Sources/TemplateKit/PeriodicConfig.swift Sources/Checks/PeriodicConfigChecks.swift Sources/Checks/main.swift
git commit -m "feat(templatekit): PeriodicConfig parse + notePath/templatePath"
```

---

## Task 4: planOpen + OpenAction

**Files:**
- Modify: `Sources/TemplateKit/PeriodicConfig.swift` (append)
- Create: `Sources/Checks/PeriodicPlanChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — `Sources/Checks/PeriodicPlanChecks.swift`

```swift
import Foundation
import TemplateKit

func periodicPlanChecks() {
    let utc = TimeZone(identifier: "UTC")!
    var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 9
    var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
    let d = cal.date(from: c)!
    let cfg = PeriodicConfig([.daily: PeriodicSettings(folder: "Daily", format: "YYYY-MM-DD", template: "Templates/Daily.md")])

    // Existing note → .open
    let openAction = cfg.planOpen(.daily, date: d,
                                  exists: { _ in true },
                                  readTemplate: { _ in nil },
                                  now: d, timeZone: utc)
    expectEqual(openAction, .open(path: "Daily/2026-06-09.md"), "existing note → open")

    // Missing note → .create with rendered template + cursor
    let template = "# <% tp.file.title %>\n<% tp.date.now(\"YYYY-MM-DD\") %>\n<% tp.file.cursor() %>"
    let createAction = cfg.planOpen(.daily, date: d,
                                    exists: { _ in false },
                                    readTemplate: { path in path == "Templates/Daily.md" ? template : nil },
                                    now: d, timeZone: utc)
    if case let .create(path, text, cursor) = createAction {
        expectEqual(path, "Daily/2026-06-09.md", "create path")
        expectEqual(text, "# 2026-06-09\n2026-06-09\n", "template rendered (title = filename base)")
        expect(cursor == text.utf16.count, "cursor at end where token was")
    } else {
        expect(false, "missing note should produce .create")
    }

    // Missing note, no template → empty body
    let cfg2 = PeriodicConfig([.daily: PeriodicSettings(folder: "", format: "YYYY-MM-DD", template: nil)])
    let bare = cfg2.planOpen(.daily, date: d, exists: { _ in false }, readTemplate: { _ in nil }, now: d, timeZone: utc)
    expectEqual(bare, .create(path: "2026-06-09.md", text: "", cursor: nil), "no template → empty create")
}
```

- [ ] **Step 2: Register the group**

Add `("PeriodicPlan", periodicPlanChecks),` to `main.swift`.

- [ ] **Step 3: Run to verify it fails**

Run: `swift run Checks PeriodicPlan`
Expected: build failure — `cannot find 'OpenAction' / value of type 'PeriodicConfig' has no member 'planOpen'`.

- [ ] **Step 4: Implement (append to `Sources/TemplateKit/PeriodicConfig.swift`)**

```swift
public enum OpenAction: Equatable {
    case open(path: String)
    case create(path: String, text: String, cursor: Int?)
}

extension PeriodicConfig {
    /// Decide whether to open an existing periodic note or create one from its template.
    public func planOpen(_ kind: PeriodicKind, date: Date,
                         exists: (String) -> Bool,
                         readTemplate: (String) -> String?,
                         now: Date = Date(),
                         timeZone: TimeZone = .current) -> OpenAction {
        let path = notePath(kind, date: date, timeZone: timeZone)
        if exists(path) { return .open(path: path) }
        let base = (path as NSString).lastPathComponent
        let title = (base as NSString).deletingPathExtension
        let templateText = templatePath(kind).flatMap { readTemplate($0) } ?? ""
        let rendered = TemplateEngine.render(templateText,
            TemplateContext(now: now, title: title, creationDate: now, timeZone: timeZone))
        return .create(path: path, text: rendered.text, cursor: rendered.cursorOffset)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run Checks PeriodicPlan`
Expected: `✅ All checks passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/TemplateKit/PeriodicConfig.swift Sources/Checks/PeriodicPlanChecks.swift Sources/Checks/main.swift
git commit -m "feat(templatekit): planOpen/OpenAction periodic note planning"
```

---

## Task 5: TemplaterConfig (templates folder)

**Files:**
- Create: `Sources/TemplateKit/TemplaterConfig.swift`
- Create: `Sources/Checks/TemplaterConfigChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — `Sources/Checks/TemplaterConfigChecks.swift`

```swift
import Foundation
import TemplateKit

func templaterConfigChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-tpl-\(UUID().uuidString)")
    let dir = vault.appendingPathComponent(".obsidian/plugins/templater-obsidian")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }

    expectEqual(TemplaterConfig.templatesFolder(vaultRoot: vault), "Templates", "default when no config")
    try? "{ \"templates_folder\": \"Meta/Templates\" }".write(
        to: dir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    expectEqual(TemplaterConfig.templatesFolder(vaultRoot: vault), "Meta/Templates", "reads templates_folder")
}
```

- [ ] **Step 2: Register the group**

Add `("TemplaterConfig", templaterConfigChecks),` to `main.swift`.

- [ ] **Step 3: Run to verify it fails**

Run: `swift run Checks TemplaterConfig`
Expected: build failure — `cannot find 'TemplaterConfig' in scope`.

- [ ] **Step 4: Implement `Sources/TemplateKit/TemplaterConfig.swift`**

```swift
import Foundation

public enum TemplaterConfig {
    /// The Templater plugin's templates folder (vault-relative), default "Templates".
    public static func templatesFolder(vaultRoot: URL) -> String {
        let url = vaultRoot.appendingPathComponent(".obsidian/plugins/templater-obsidian/data.json")
        if let data = try? Data(contentsOf: url),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let folder = obj["templates_folder"] as? String, !folder.isEmpty {
            return folder
        }
        return "Templates"
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run Checks TemplaterConfig`
Expected: `✅ All checks passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/TemplateKit/TemplaterConfig.swift Sources/Checks/TemplaterConfigChecks.swift Sources/Checks/main.swift
git commit -m "feat(templatekit): TemplaterConfig templates folder"
```

---

## Task 6: FuzzyFilter (palette matching)

**Files:**
- Create: `Sources/MarkdownCore/FuzzyFilter.swift`
- Create: `Sources/Checks/FuzzyFilterChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Write the failing test** — `Sources/Checks/FuzzyFilterChecks.swift`

```swift
import Foundation
import MarkdownCore

func fuzzyFilterChecks() {
    expect(FuzzyFilter.score("dv", "Daily View") != nil, "subsequence matches (case-insensitive)")
    expect(FuzzyFilter.score("xyz", "Daily") == nil, "non-subsequence → nil")
    expect(FuzzyFilter.score("", "anything") == 0, "empty query scores 0")
    // Closer-together matches rank better (lower score).
    let tight = FuzzyFilter.score("ab", "abXX")!
    let loose = FuzzyFilter.score("ab", "aXXb")!
    expect(tight < loose, "contiguous match ranks before scattered")

    let items = ["Open today's daily note", "Open this week's note", "New note from template…"]
    let filtered = FuzzyFilter.filter("tmpl", items, key: { $0 })
    expectEqual(filtered.first, "New note from template…", "fuzzy filter ranks best match first")
    expectEqual(FuzzyFilter.filter("", items, key: { $0 }).count, 3, "empty query keeps all")
}
```

- [ ] **Step 2: Register the group**

Add `("FuzzyFilter", fuzzyFilterChecks),` to `main.swift`.

- [ ] **Step 3: Run to verify it fails**

Run: `swift run Checks FuzzyFilter`
Expected: build failure — `cannot find 'FuzzyFilter' in scope`.

- [ ] **Step 4: Implement `Sources/MarkdownCore/FuzzyFilter.swift`**

```swift
import Foundation

/// Case-insensitive subsequence matching with a simple proximity score (lower = better).
public enum FuzzyFilter {
    public static func score(_ query: String, _ text: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        var qi = 0
        var firstMatch: Int? = nil
        var lastMatch = -1
        var gaps = 0
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            if firstMatch == nil { firstMatch = ti }
            if lastMatch >= 0 { gaps += ti - lastMatch - 1 }
            lastMatch = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        return (firstMatch ?? 0) + gaps
    }

    public static func filter<T>(_ query: String, _ items: [T], key: (T) -> String) -> [T] {
        if query.isEmpty { return items }
        return items
            .compactMap { item in score(query, key(item)).map { (item, $0) } }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run Checks FuzzyFilter`
Expected: `✅ All checks passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/MarkdownCore/FuzzyFilter.swift Sources/Checks/FuzzyFilterChecks.swift Sources/Checks/main.swift
git commit -m "feat(core): FuzzyFilter for palette matching"
```

---

## Task 7: AppState — recent vaults, file ops, pending cursor

**Files:**
- Modify: `Sources/AppCore/AppState.swift`
- Modify: `Sources/Checks/AppStateChecks.swift`

- [ ] **Step 1: Write the failing test** — append to `Sources/Checks/AppStateChecks.swift` (add this function, then call it from `appStateChecks` or register separately)

Add a new function and register it as its own group:
```swift
func appRecentsChecks() {
    let fm = FileManager.default
    let suite = "mk-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let a = fm.temporaryDirectory.appendingPathComponent("vault-a-\(UUID().uuidString)")
    let b = fm.temporaryDirectory.appendingPathComponent("vault-b-\(UUID().uuidString)")
    try? fm.createDirectory(at: a, withIntermediateDirectories: true)
    try? fm.createDirectory(at: b, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }

    let s1 = AppState(defaults: defaults)
    s1.openVault(at: a)
    s1.openVault(at: b)
    s1.openVault(at: a)          // re-open a → moves to front, no duplicate
    expectEqual(s1.recentVaults.count, 2, "dedupe keeps two vaults")
    expectEqual(s1.recentVaults.first?.standardizedFileURL, a.standardizedFileURL, "most recent first")

    // Persisted across instances.
    let s2 = AppState(defaults: defaults)
    expectEqual(s2.recentVaults.first?.standardizedFileURL, a.standardizedFileURL, "recents persist + reload")

    s2.removeRecent(a)
    expectEqual(s2.recentVaults.count, 1, "removeRecent drops one")
    s2.clearRecents()
    expect(s2.recentVaults.isEmpty, "clearRecents empties")
}

func appCreateNoteChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-create-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let state = AppState(defaults: UserDefaults(suiteName: "mk-c-\(UUID().uuidString)")!)
    state.openVault(at: root)
    expect(!state.noteExists(relativePath: "Daily/2026-06-09.md"), "note absent before create")
    state.createNote(relativePath: "Daily/2026-06-09.md", text: "# Hi", cursorOffset: 3)
    expect(state.noteExists(relativePath: "Daily/2026-06-09.md"), "note exists after create (folder auto-made)")
    expectEqual(state.readNote(relativePath: "Daily/2026-06-09.md"), "# Hi", "content written")
    expectEqual(state.pendingCursorOffset, 3, "pendingCursorOffset set")
    expect(state.files.contains { $0.name == "2026-06-09.md" }, "file list refreshed")

    state.openNote(relativePath: "Daily/2026-06-09.md")
    expectEqual(state.selectedFile?.name, "2026-06-09.md", "openNote selects the file")
    expectEqual(state.activeText, "# Hi", "openNote loads text")
}
```

- [ ] **Step 2: Register the groups**

Add to `main.swift`: `("AppRecents", appRecentsChecks),` and `("AppCreateNote", appCreateNoteChecks),`.

- [ ] **Step 3: Run to verify it fails**

Run: `swift run Checks AppRecents`
Expected: build failure — `AppState` has no `init(defaults:)` / `recentVaults` / `removeRecent` / `noteExists` etc.

- [ ] **Step 4: Implement — rewrite `Sources/AppCore/AppState.swift`**

```swift
import Foundation
import Combine
import VaultKit
import MarkdownCore

public final class AppState: ObservableObject {
    @Published public var vaultRoot: URL?
    @Published public var files: [MarkdownFile] = []
    @Published public var selectedFile: MarkdownFile?
    @Published public var activeText: String = ""
    @Published public var index: MetadataIndex = MetadataIndex()
    @Published public var recentVaults: [URL] = []
    @Published public var pendingCursorOffset: Int?
    public let rendererRegistry = DefaultRendererRegistry()

    private var vault: Vault?
    private let defaults: UserDefaults
    private static let recentsKey = "io.hanji.recentVaults"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let paths = (defaults.array(forKey: Self.recentsKey) as? [String]) ?? []
        recentVaults = paths.map { URL(fileURLWithPath: $0) }
    }

    public func openVault(at root: URL) {
        let v = Vault(root: root)
        vault = v
        vaultRoot = root
        files = (try? v.markdownFiles()) ?? []
        index = (try? MetadataIndex.build(from: v)) ?? MetadataIndex()
        selectedFile = nil
        activeText = ""
        addRecent(root)
    }

    public func open(_ file: MarkdownFile) {
        selectedFile = file
        activeText = (try? vault?.read(file)) ?? ""
    }

    public func save() {
        guard let file = selectedFile, let vault else { return }
        try? vault.write(activeText, to: file)
    }

    // MARK: - Recent vaults

    private func addRecent(_ root: URL) {
        let std = root.standardizedFileURL
        var list = recentVaults.filter { $0.standardizedFileURL != std }
        list.insert(std, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        recentVaults = list
        persistRecents()
    }

    public func removeRecent(_ url: URL) {
        recentVaults.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        persistRecents()
    }

    public func clearRecents() {
        recentVaults = []
        persistRecents()
    }

    private func persistRecents() {
        defaults.set(recentVaults.map { $0.path }, forKey: Self.recentsKey)
    }

    // MARK: - Note operations (used by WorkspaceActions)

    public func noteExists(relativePath: String) -> Bool {
        guard let root = vaultRoot else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    public func readNote(relativePath: String) -> String? {
        guard let root = vaultRoot else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    public func createNote(relativePath: String, text: String, cursorOffset: Int?) {
        guard let root = vaultRoot else { return }
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        if let v = vault {
            files = (try? v.markdownFiles()) ?? files
            index = (try? MetadataIndex.build(from: v)) ?? index
        }
        pendingCursorOffset = cursorOffset
    }

    public func openNote(relativePath: String) {
        guard let root = vaultRoot else { return }
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        if let f = files.first(where: { $0.url.standardizedFileURL == target }) { open(f); return }
        if let v = vault { files = (try? v.markdownFiles()) ?? files }
        if let f = files.first(where: { $0.url.standardizedFileURL == target }) { open(f) }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift run Checks AppRecents AppCreateNote AppState`
Expected: `✅ All checks passed` for all three groups.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppCore/AppState.swift Sources/Checks/AppStateChecks.swift Sources/Checks/main.swift
git commit -m "feat(appcore): recent vaults + note create/open + pending cursor"
```

---

## Task 8: SDK ③ commands + workspace + Host conformance

**Files:**
- Modify: `Sources/ExtensionSDK/ExtensionSDK.swift`
- Modify: `Sources/AppCore/PluginManager.swift`
- Modify: `Sources/AppCore/Host.swift`
- Create: `Sources/Checks/CommandRegistryChecks.swift`
- Modify: `Sources/Checks/main.swift`

> These changes are interlocking: extending `PluginHost` breaks `Host` until it conforms, so implement all three source files before building.

- [ ] **Step 1: Write the failing test** — `Sources/Checks/CommandRegistryChecks.swift`

```swift
import Foundation
import ExtensionSDK
import AppCore

private struct CommandPlugin: Plugin {
    static let id = "test.command"
    init() {}
    func activate(host: PluginHost) {
        host.commands.register(Command(id: "test.run", title: "Run Test") { })
    }
}

func commandRegistryChecks() {
    let appState = AppState(defaults: UserDefaults(suiteName: "mk-cmd-\(UUID().uuidString)")!)
    let pm = PluginManager()
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([CommandPlugin()], host: host)
    expectEqual(pm.commands.count, 1, "plugin registers one command")
    expectEqual(pm.commands.first?.title ?? "", "Run Test", "command title")

    // WorkspaceActions reaches AppState.
    expect(host.workspace.vaultRoot == nil, "no vault yet")
}
```

- [ ] **Step 2: Register the group**

Add `("CommandRegistry2", commandRegistryChecks),` to `main.swift`. (Name avoids clashing with the existing renderer `RendererRegistry` group; pick any unused name.)

- [ ] **Step 3: Run to verify it fails**

Run: `swift run Checks CommandRegistry2`
Expected: build failure — `cannot find 'Command'` / `value of type 'Host' has no member 'commands'`.

- [ ] **Step 4: Implement — add to `Sources/ExtensionSDK/ExtensionSDK.swift`**

At the top, ensure Foundation is imported:
```swift
import Foundation
```
Append these declarations:
```swift
/// Surface ③ (commands): a user-invokable action shown in the ⌘P palette.
public struct Command: Identifiable {
    public let id: String
    public let title: String
    public let run: () -> Void
    public init(id: String, title: String, run: @escaping () -> Void) {
        self.id = id; self.title = title; self.run = run
    }
}

public protocol CommandRegistry: AnyObject {
    func register(_ command: Command)
}

/// Vault note actions handed to plugins (create/open notes, choose files).
public protocol WorkspaceActions: AnyObject {
    var vaultRoot: URL? { get }
    func noteExists(relativePath: String) -> Bool
    func readNote(relativePath: String) -> String?
    func createNote(relativePath: String, text: String, cursorOffset: Int?)
    func openNote(relativePath: String)
    func pickNote(title: String, startingFolder: String?) -> String?
    func promptNewNotePath(suggestedName: String) -> String?
}
```
Extend the `PluginHost` protocol to add two members:
```swift
public protocol PluginHost: AnyObject {
    var ui: UIRegistry { get }
    var editor: EditorContext { get }
    var renderers: RendererRegistry { get }
    var commands: CommandRegistry { get }
    var workspace: WorkspaceActions { get }
}
```

- [ ] **Step 5: Implement — add to `Sources/AppCore/PluginManager.swift`**

```swift
@Published public private(set) var commands: [Command] = []
func addCommand(_ command: Command) { commands.append(command) }
```
(Add the property next to `sidebar` and the method next to `addSidebar`.)

- [ ] **Step 6: Implement — extend `Sources/AppCore/Host.swift`**

Replace the file with:
```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import ExtensionSDK

/// Concrete host wiring AppState + PluginManager to the SDK surfaces.
public final class Host: PluginHost, UIRegistry, EditorContext, CommandRegistry, WorkspaceActions {
    private let appState: AppState
    private let pluginManager: PluginManager

    public init(appState: AppState, pluginManager: PluginManager) {
        self.appState = appState
        self.pluginManager = pluginManager
    }

    // PluginHost
    public var ui: UIRegistry { self }
    public var editor: EditorContext { self }
    public var renderers: RendererRegistry { appState.rendererRegistry }
    public var commands: CommandRegistry { self }
    public var workspace: WorkspaceActions { self }

    // UIRegistry
    public func addSidebarView(id: String, title: String, _ make: @escaping () -> AnyView) {
        pluginManager.addSidebar(SidebarContribution(id: id, title: title, makeView: make))
    }

    // EditorContext
    public var activeText: AnyPublisher<String, Never> { appState.$activeText.eraseToAnyPublisher() }

    // CommandRegistry
    public func register(_ command: Command) { pluginManager.addCommand(command) }

    // WorkspaceActions
    public var vaultRoot: URL? { appState.vaultRoot }
    public func noteExists(relativePath: String) -> Bool { appState.noteExists(relativePath: relativePath) }
    public func readNote(relativePath: String) -> String? { appState.readNote(relativePath: relativePath) }
    public func createNote(relativePath: String, text: String, cursorOffset: Int?) {
        appState.createNote(relativePath: relativePath, text: text, cursorOffset: cursorOffset)
    }
    public func openNote(relativePath: String) { appState.openNote(relativePath: relativePath) }

    public func pickNote(title: String, startingFolder: String?) -> String? {
        guard let root = appState.vaultRoot else { return nil }
        let panel = NSOpenPanel()
        panel.message = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        if let sf = startingFolder { panel.directoryURL = root.appendingPathComponent(sf) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Self.relativePath(of: url, under: root)
    }

    public func promptNewNotePath(suggestedName: String) -> String? {
        guard let root = appState.vaultRoot else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = root
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Self.relativePath(of: url, under: root)
    }

    private static func relativePath(of url: URL, under root: URL) -> String? {
        let r = root.standardizedFileURL.path
        let u = url.standardizedFileURL.path
        guard u.hasPrefix(r) else { return nil }
        return String(u.dropFirst(r.count).drop(while: { $0 == "/" }))
    }
}
```

- [ ] **Step 7: Run to verify it passes**

Run: `swift run Checks CommandRegistry2 PluginLoop`
Expected: `✅ All checks passed` (PluginLoop still green confirms existing surfaces unbroken).

- [ ] **Step 8: Commit**

```bash
git add Sources/ExtensionSDK/ExtensionSDK.swift Sources/AppCore/PluginManager.swift Sources/AppCore/Host.swift Sources/Checks/CommandRegistryChecks.swift Sources/Checks/main.swift
git commit -m "feat(sdk): Command/CommandRegistry + WorkspaceActions + Host conformance"
```

---

## Task 9: PeriodicNotesPlugin

**Files:**
- Create: `Sources/PeriodicNotesPlugin/PeriodicNotesPlugin.swift`
- Modify: `Package.swift`
- Create: `Sources/Checks/PeriodicNotesPluginChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Add the target in `Package.swift`**

Add to `targets:`:
```swift
        .target(name: "PeriodicNotesPlugin", dependencies: ["ExtensionSDK", "TemplateKit"]),
```
Add `"PeriodicNotesPlugin"` to the `Checks` target's `dependencies` array.

- [ ] **Step 2: Write the failing test** — `Sources/Checks/PeriodicNotesPluginChecks.swift`

This drives the full stack headlessly (Host + AppState + temp vault; the daily path never opens a panel):
```swift
import Foundation
import ExtensionSDK
import AppCore
import PeriodicNotesPlugin

func periodicNotesPluginChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mk-pn-\(UUID().uuidString)")
    let templates = root.appendingPathComponent("Templates")
    try? fm.createDirectory(at: templates, withIntermediateDirectories: true)
    let pluginDir = root.appendingPathComponent(".obsidian/plugins/periodic-notes")
    try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? "{ \"daily\": { \"folder\": \"Daily\", \"format\": \"YYYY-MM-DD\", \"template\": \"Templates/Daily\" } }"
        .write(to: pluginDir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    try? "# <% tp.file.title %>".write(to: templates.appendingPathComponent("Daily.md"), atomically: true, encoding: .utf8)

    let appState = AppState(defaults: UserDefaults(suiteName: "mk-pn-\(UUID().uuidString)")!)
    appState.openVault(at: root)
    let pm = PluginManager()
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([PeriodicNotesPlugin()], host: host)

    expectEqual(pm.commands.count, 3, "daily/weekly/monthly commands registered")
    guard let today = pm.commands.first(where: { $0.id == "periodic.daily" }) else {
        expect(false, "daily command missing"); return
    }
    today.run()

    let created = appState.readNote(relativePath: "Daily/" + isoToday() + ".md")
    expect(created != nil, "daily note created from template")
    expectEqual(appState.selectedFile?.name, isoToday() + ".md", "created note is opened")
}

private func isoToday() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date())
}
```

- [ ] **Step 3: Register the group**

Add `("PeriodicNotesPlugin", periodicNotesPluginChecks),` to `main.swift`.

- [ ] **Step 4: Run to verify it fails**

Run: `swift run Checks PeriodicNotesPlugin`
Expected: build failure — `no such module 'PeriodicNotesPlugin'` / `cannot find 'PeriodicNotesPlugin' in scope`.

- [ ] **Step 5: Implement `Sources/PeriodicNotesPlugin/PeriodicNotesPlugin.swift`**

```swift
import Foundation
import ExtensionSDK
import TemplateKit

public struct PeriodicNotesPlugin: Plugin {
    public static let id = "io.hanji.periodicnotes"
    public init() {}

    public func activate(host: PluginHost) {
        register(host, kind: .daily,   title: "Open today's daily note")
        register(host, kind: .weekly,  title: "Open this week's note")
        register(host, kind: .monthly, title: "Open this month's note")
    }

    private func register(_ host: PluginHost, kind: PeriodicKind, title: String) {
        host.commands.register(Command(id: "periodic.\(kind.rawValue)", title: title) { [weak ws = host.workspace] in
            guard let ws, let root = ws.vaultRoot else { return }
            let cfg = PeriodicConfig.load(vaultRoot: root)
            let action = cfg.planOpen(kind, date: Date(),
                                      exists: { ws.noteExists(relativePath: $0) },
                                      readTemplate: { ws.readNote(relativePath: $0) },
                                      now: Date())
            switch action {
            case .open(let path):
                ws.openNote(relativePath: path)
            case .create(let path, let text, let cursor):
                ws.createNote(relativePath: path, text: text, cursorOffset: cursor)
                ws.openNote(relativePath: path)
            }
        })
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `swift run Checks PeriodicNotesPlugin`
Expected: `✅ All checks passed`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/PeriodicNotesPlugin/PeriodicNotesPlugin.swift Sources/Checks/PeriodicNotesPluginChecks.swift Sources/Checks/main.swift
git commit -m "feat(periodicnotes): daily/weekly/monthly open-or-create commands"
```

---

## Task 10: TemplaterPlugin

**Files:**
- Create: `Sources/TemplaterPlugin/TemplaterPlugin.swift`
- Modify: `Package.swift`

> The command body is panel-gated (`pickNote`/`promptNewNotePath`), which cannot run headlessly, so this task is build-verified; behavior is covered by the E2E in Task 14 and by TemplateEngine/TemplaterConfig unit tests.

- [ ] **Step 1: Add the target in `Package.swift`**

Add to `targets:`:
```swift
        .target(name: "TemplaterPlugin", dependencies: ["ExtensionSDK", "TemplateKit"]),
```

- [ ] **Step 2: Implement `Sources/TemplaterPlugin/TemplaterPlugin.swift`**

```swift
import Foundation
import ExtensionSDK
import TemplateKit

public struct TemplaterPlugin: Plugin {
    public static let id = "io.hanji.templater"
    public init() {}

    public func activate(host: PluginHost) {
        host.commands.register(Command(id: "templater.newFromTemplate", title: "New note from template…") { [weak ws = host.workspace] in
            guard let ws, let root = ws.vaultRoot else { return }
            let folder = TemplaterConfig.templatesFolder(vaultRoot: root)
            guard let templateRel = ws.pickNote(title: "Choose a template", startingFolder: folder) else { return }
            let templateText = ws.readNote(relativePath: templateRel) ?? ""
            guard let newRel = ws.promptNewNotePath(suggestedName: "Untitled.md") else { return }
            let base = ((newRel as NSString).lastPathComponent as NSString).deletingPathExtension
            let rendered = TemplateEngine.render(templateText,
                TemplateContext(now: Date(), title: base, creationDate: Date()))
            ws.createNote(relativePath: newRel, text: rendered.text, cursorOffset: rendered.cursorOffset)
            ws.openNote(relativePath: newRel)
        })
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/TemplaterPlugin/TemplaterPlugin.swift
git commit -m "feat(templater): New note from template command"
```

---

## Task 11: Editor — apply pendingCursorOffset on open

**Files:**
- Modify: `Sources/EditorEngine/MarkdownEditorView.swift`
- Modify: `Sources/HanjiApp/ContentView.swift` (pass the binding)

> Read `Sources/EditorEngine/MarkdownEditorView.swift` first to see the existing `MarkdownEditorView` initializer and `updateNSView`. Add a new `cursorOffset` binding and apply it.

- [ ] **Step 1: Add the parameter to `MarkdownEditorView`**

Add a stored property and initializer parameter:
```swift
var cursorOffset: Binding<Int?>
```
Update the initializer signature to accept `cursorOffset: Binding<Int?>` and assign it. (Match the existing `init` style — it currently takes `text:`, `renderers:`, `vaultRoot:`.)

- [ ] **Step 2: Apply it in `updateNSView`**

At the end of `updateNSView(_:context:)`, after the existing text-sync/restyle, add:
```swift
if let offset = cursorOffset.wrappedValue,
   let textView = scrollView.documentView as? NSTextView {
    let clamped = max(0, min(offset, (textView.string as NSString).length))
    textView.setSelectedRange(NSRange(location: clamped, length: 0))
    textView.scrollRangeToVisible(NSRange(location: clamped, length: 0))
    textView.window?.makeFirstResponder(textView)
    DispatchQueue.main.async { cursorOffset.wrappedValue = nil }
}
```
(Use the actual scroll-view parameter name from the existing signature; the editor wraps an `NSTextView` in an `NSScrollView`.)

- [ ] **Step 3: Pass the binding from `ContentView`**

In `ContentView.swift`, change the editor construction to pass the cursor binding:
```swift
MarkdownEditorView(text: $appState.activeText,
                   renderers: appState.rendererRegistry,
                   vaultRoot: appState.vaultRoot,
                   cursorOffset: $appState.pendingCursorOffset)
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`.

- [ ] **Step 5: Commit**

```bash
git add Sources/EditorEngine/MarkdownEditorView.swift Sources/HanjiApp/ContentView.swift
git commit -m "feat(editor): place caret at pendingCursorOffset on note open"
```

---

## Task 12: Command palette (⌘P) + quick switcher (⌘O)

**Files:**
- Create: `Sources/HanjiApp/UIState.swift`
- Create: `Sources/HanjiApp/PaletteView.swift`
- Modify: `Sources/HanjiApp/ContentView.swift`
- Modify: `Sources/HanjiApp/HanjiApp.swift`
- Modify: `Package.swift` (HanjiApp deps: add `MarkdownCore`, `TemplateKit`, `PeriodicNotesPlugin`, `TemplaterPlugin`)

- [ ] **Step 1: Add HanjiApp dependencies in `Package.swift`**

Change the `HanjiApp` executable target dependencies to:
```swift
        .executableTarget(name: "HanjiApp", dependencies: [
            "AppCore", "EditorEngine", "ExtensionSDK", "WordCountPlugin", "CoreRenderers",
            "VaultKit", "MarkdownCore", "TemplateKit", "PeriodicNotesPlugin", "TemplaterPlugin"
        ]),
```

- [ ] **Step 2: Create `Sources/HanjiApp/UIState.swift`**

```swift
import SwiftUI

enum PaletteMode { case commands, files }

@MainActor
final class UIState: ObservableObject {
    @Published var palette: PaletteMode?
}
```

- [ ] **Step 3: Create `Sources/HanjiApp/PaletteView.swift`**

```swift
import SwiftUI
import MarkdownCore

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let action: () -> Void
}

struct PaletteView: View {
    let placeholder: String
    let items: [PaletteItem]
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var filtered: [PaletteItem] {
        FuzzyFilter.filter(query, items, key: { $0.title })
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onChange(of: query) { _, _ in selection = 0 }
            Divider()
            ScrollViewReader { proxy in
                List(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(idx == selection ? Color.accentColor.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { run(item) }
                    .id(idx)
                }
                .onChange(of: selection) { _, new in proxy.scrollTo(new) }
            }
        }
        .frame(width: 560, height: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 24)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, filtered.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.return) { if filtered.indices.contains(selection) { run(filtered[selection]) }; return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func run(_ item: PaletteItem) {
        onClose()
        item.action()
    }
}
```

- [ ] **Step 4: Wire the overlay + Welcome split in `ContentView.swift`**

Add `@EnvironmentObject var uiState: UIState` to `ContentView`. Wrap the body so the existing `NavigationSplitView` becomes a computed `splitView` and add the overlay:
```swift
var body: some View {
    Group {
        if appState.vaultRoot == nil {
            WelcomeView(onOpen: openVault, onOpenRecent: openRecent)
        } else {
            splitView
        }
    }
    .overlay { paletteOverlay }
}

@ViewBuilder private var paletteOverlay: some View {
    if let mode = uiState.palette {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15).ignoresSafeArea().onTapGesture { uiState.palette = nil }
            paletteView(for: mode).padding(.top, 80)
        }
    }
}

private func paletteView(for mode: PaletteMode) -> some View {
    switch mode {
    case .commands:
        return PaletteView(placeholder: "Run a command…",
                           items: pluginManager.commands.map { c in
                               PaletteItem(id: c.id, title: c.title, subtitle: nil, action: c.run)
                           },
                           onClose: { uiState.palette = nil })
    case .files:
        return PaletteView(placeholder: "Go to file…",
                           items: appState.files.map { f in
                               PaletteItem(id: f.url.path, title: f.name, subtitle: nil,
                                           action: { appState.open(f) })
                           },
                           onClose: { uiState.palette = nil })
    }
}

private func openRecent(_ url: URL) {
    appState.openVault(at: url)
}
```
Move the current `NavigationSplitView { … }` into `private var splitView: some View { … }`, keeping its contents and the editor change from Task 11.

- [ ] **Step 5: Add ⌘P/⌘O menu commands + UIState in `HanjiApp.swift`**

Add `@StateObject private var uiState = UIState()`, inject it (`.environmentObject(uiState)`), and add a `.commands` block to the `WindowGroup`:
```swift
.commands {
    CommandMenu("Go") {
        Button("Command Palette") { uiState.palette = .commands }
            .keyboardShortcut("p", modifiers: .command)
        Button("Quick Switcher") { uiState.palette = .files }
            .keyboardShortcut("o", modifiers: .command)
    }
}
```

- [ ] **Step 6: Build, run, screenshot-verify**

```bash
swift build && swift run hanji
```
Then (separate shell): launch with the demo vault and capture:
```bash
HANJI_OPEN_VAULT=<demo-vault> swift run hanji &
sleep 4 && screencapture -x /tmp/mk-palette.png
```
Press ⌘P (command palette appears with the three "Open … note" commands + "New note from template…") and ⌘O (file list). Read `/tmp/mk-palette.png` to confirm the overlay renders and filters as you type.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/HanjiApp/UIState.swift Sources/HanjiApp/PaletteView.swift Sources/HanjiApp/ContentView.swift Sources/HanjiApp/HanjiApp.swift
git commit -m "feat(shell): ⌘P command palette + ⌘O quick switcher overlay"
```

---

## Task 13: WelcomeView + launch auto-reopen + Settings + register plugins

**Files:**
- Create: `Sources/HanjiApp/WelcomeView.swift`
- Create: `Sources/HanjiApp/SettingsView.swift`
- Modify: `Sources/HanjiApp/HanjiApp.swift`

- [ ] **Step 1: Create `Sources/HanjiApp/WelcomeView.swift`**

```swift
import SwiftUI
import AppCore

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    let onOpen: () -> Void
    let onOpenRecent: (URL) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Hanji").font(.largeTitle.bold())
            Text("Open a folder of .md files to get started")
                .foregroundStyle(.secondary)
            Button("Open Vault…", action: onOpen)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            if !appState.recentVaults.isEmpty {
                Divider().frame(maxWidth: 380).padding(.vertical, 8)
                Text("Recent").font(.headline).frame(maxWidth: 380, alignment: .leading)
                ForEach(appState.recentVaults, id: \.self) { url in
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    Button { onOpenRecent(url) } label: {
                        HStack {
                            Image(systemName: "folder")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if !exists { Text("missing").font(.caption).foregroundStyle(.red) }
                        }
                        .frame(maxWidth: 380, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(!exists)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
```

- [ ] **Step 2: Create `Sources/HanjiApp/SettingsView.swift`**

```swift
import SwiftUI
import AppCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vault").font(.headline)
            Text(appState.vaultRoot?.path ?? "No vault open").foregroundStyle(.secondary)

            Divider()
            HStack {
                Text("Recent vaults").font(.headline)
                Spacer()
                Button("Clear", role: .destructive) { appState.clearRecents() }
                    .disabled(appState.recentVaults.isEmpty)
            }
            if appState.recentVaults.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                ForEach(appState.recentVaults, id: \.self) { url in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent)
                            Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Open") { appState.openVault(at: url) }
                            .disabled(!FileManager.default.fileExists(atPath: url.path))
                        Button("Remove") { appState.removeRecent(url) }
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 460, height: 340)
    }
}
```

- [ ] **Step 3: Register plugins + Settings scene + launch behavior in `HanjiApp.swift`**

Add imports `import PeriodicNotesPlugin` and `import TemplaterPlugin`. In the plugin-activation block, change the plugins array to:
```swift
let plugins: [Plugin] = [WordCountPlugin(), PeriodicNotesPlugin(), TemplaterPlugin()]
```
Replace the `HANJI_OPEN_VAULT` block with launch logic that prefers the env hook, else auto-reopens the most recent existing vault:
```swift
if let vaultPath = ProcessInfo.processInfo.environment["HANJI_OPEN_VAULT"] {
    let url = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
    appState.openVault(at: url)
    if let first = appState.files.first { appState.open(first) }
} else if let recent = appState.recentVaults.first,
          FileManager.default.fileExists(atPath: recent.path) {
    appState.openVault(at: recent)   // reopen last vault; user picks a note via ⌘O / list
}
```
Add a `Settings` scene to `body`:
```swift
Settings {
    SettingsView().environmentObject(appState)
}
```
(Place it as a second scene alongside `WindowGroup` inside `var body: some Scene`.)

- [ ] **Step 4: Build, run, screenshot-verify the welcome screen**

```bash
# fresh first-run: clear persisted recents so WelcomeView shows
defaults delete io.hanji.app io.hanji.recentVaults 2>/dev/null || true
swift build && swift run hanji &
sleep 4 && screencapture -x /tmp/mk-welcome.png
```
Read `/tmp/mk-welcome.png`: confirm the centered "hanji" title + a prominent **Open Vault…** button. Open the demo vault via the button, quit, relaunch, and confirm it auto-reopens (and the welcome screen now lists the recent vault when no vault is open).

- [ ] **Step 5: Commit**

```bash
git add Sources/HanjiApp/WelcomeView.swift Sources/HanjiApp/SettingsView.swift Sources/HanjiApp/HanjiApp.swift
git commit -m "feat(shell): WelcomeView onboarding, recent-vault auto-reopen, Settings window"
```

---

## Task 14: Packaging, full E2E, README, finish

**Files:**
- Modify: `Scripts/bundle-app.sh`
- Modify: `README.md`
- Create (E2E fixtures): `<demo-vault>/.obsidian/plugins/periodic-notes/data.json`, `<demo-vault>/Templates/Daily.md`

- [ ] **Step 1: Make the bundle script ad-hoc sign**

In `Scripts/bundle-app.sh`, after the `cat > "$APP/Contents/Info.plist" … PLIST` block and before the final `echo`, add:
```bash
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
```

- [ ] **Step 2: Seed the demo vault for the periodic-notes E2E**

```bash
mkdir -p <demo-vault>/.obsidian/plugins/periodic-notes <demo-vault>/Templates
cat > <demo-vault>/.obsidian/plugins/periodic-notes/data.json <<'JSON'
{ "daily": { "folder": "Daily", "format": "YYYY-MM-DD", "template": "Templates/Daily" } }
JSON
cat > <demo-vault>/Templates/Daily.md <<'TMPL'
# <% tp.date.now("YYYY-MM-DD") %> — <% tp.file.title %>

<% tp.file.cursor() %>
TMPL
```

- [ ] **Step 3: Run the full check suite**

Run: `swift run Checks`
Expected: `✅ All checks passed` across all groups (the new groups: MomentFormat, TemplateEngine, PeriodicConfig, PeriodicPlan, TemplaterConfig, FuzzyFilter, AppRecents, AppCreateNote, CommandRegistry2, PeriodicNotesPlugin — plus all pre-existing groups still green).

- [ ] **Step 4: E2E — periodic note creation via ⌘P**

```bash
./Scripts/bundle-app.sh
HANJI_OPEN_VAULT=<demo-vault> open hanji.app   # (or: swift run hanji with the env var)
```
Press ⌘P → select "Open today's daily note". Confirm a `Daily/<today>.md` note is created and opened with the template rendered (date + title) and the caret on the blank line. Capture and read a screenshot to verify, then delete the generated `Daily/` note so the fixture stays clean:
```bash
sleep 3 && screencapture -x /tmp/mk-daily.png
rm -rf <demo-vault>/Daily
```

- [ ] **Step 5: Update `README.md` status section**

Add to the feature list: first-party **Periodic Notes** (daily/weekly/monthly, reads your Obsidian config) and **Templater** (`<% tp.* %>` core date/file functions); the **⌘P** command palette and **⌘O** quick switcher; a **welcome screen** with recent-vault memory + auto-reopen and a **Settings** window. Note the SDK now exposes ③ commands + a workspace note-create capability.

- [ ] **Step 6: Commit**

```bash
git add Scripts/bundle-app.sh README.md
git commit -m "chore: ad-hoc sign bundle, README, periodic-notes E2E fixtures"
```

- [ ] **Step 7: Finish the branch**

Merge `periodic-templater` → `main` (fast-forward), verify `swift run Checks`, and delete the branch.

---

## Self-review notes (verified against the spec)

- **Spec coverage:** §3 SDK (Task 8) · §4 palettes ⌘P/⌘O (Tasks 6, 12) · §5 TemplateKit MomentFormat/TemplateEngine/PeriodicConfig/planOpen/TemplaterConfig (Tasks 1–5) · §6 plugins (Tasks 9, 10) · §7 host wiring + pendingCursorOffset (Tasks 7, 8, 11) · §8 onboarding/recents/Settings/auto-reopen (Tasks 7, 13) · §9 testing (each pure task + Tasks 9, 12, 13, 14 E2E) · §10 out-of-scope respected (no ④ TemplateRegistry, no quarterly/yearly, no insert-at-caret).
- **Type consistency:** `MomentFormat.format(_:_:timeZone:locale:)`, `TemplateEngine.render(_:_:) -> RenderedTemplate`, `TemplateContext(now:title:creationDate:timeZone:)`, `PeriodicKind`/`PeriodicSettings(folder:format:template:)`/`PeriodicConfig`, `OpenAction.open(path:)`/`.create(path:text:cursor:)`, `planOpen(_:date:exists:readTemplate:now:timeZone:)`, `WorkspaceActions` (7 members), `Command(id:title:run:)`, `FuzzyFilter.score/filter`, `AppState.init(defaults:)` + `recentVaults`/`removeRecent`/`clearRecents`/`noteExists`/`readNote`/`createNote`/`openNote`/`pendingCursorOffset` — names are used identically across tasks.
- **No placeholders:** every code/test/command step contains the literal content to type.
