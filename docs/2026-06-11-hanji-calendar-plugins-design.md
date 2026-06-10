# hanji — Calendar Panel + Obsidian-style Plugin Toggles

Design doc · 2026-06-11 · Epic E of the v1 close-out roadmap
Completes M4 (PRD: Calendar 패널) and restores the PRD's plugin on/off model
("PeriodicNotes 기본 ON" implies toggleability; `deactivate()` was dropped in M0).

## 1. Goal

1. **Plugin toggles**: Settings ▸ Plugins lists every first-party plugin with an
   Obsidian-style on/off switch — applied live (no restart), persisted.
2. **Calendar panel**: a right-sidebar month grid (second panel, under
   Backlinks) with dots on days that have a daily note; clicking a day
   opens-or-creates that day's note through the same periodic-notes pipeline.

### Decisions (locked)

- **D-toggle:** Approach A — `PluginManager` tags every registration (sidebar /
  command / status item) with the plugin id that made it, by tracking an
  `activatingPluginID` during each `activate()` call. Toggling off removes the
  tagged registrations and calls `deactivate()`; toggling on re-runs
  `activate(host:)`. Existing plugins need **zero changes** to become
  toggleable.
- **D-default:** All plugins default to enabled; persisted per id at
  `io.hanji.plugin.<id>.enabled`.
- **D-limitation:** Code-block renderers (surface ①) are registered by the app
  itself today (no plugin registers one), so renderer tracking is explicitly
  out of toggle scope — documented in code.
- **D-calendar:** Month grid uses `Calendar.current` (locale week start);
  daily notes only (weekly row is roadmap); dots via
  `PeriodicConfig.notePath(.daily,date:)` + `workspace.noteExists` for the
  visible ≤42 days; click = `planOpen(.daily, date:)` open-or-create.

## 2. Architecture & flow (시각화)

```
 Settings ▸ Plugins 탭                       PluginManager
 ┌──────────────────────┐  setEnabled(id,on) ┌──────────────────────────────┐
 │ Word Count      [ON] │───────────────────▶│ registry: [(id, name, inst)]  │
 │ Periodic Notes  [ON] │                    │ enabled:  UserDefaults        │
 │ Templater       [ON] │     ┌──────────────│ activatingPluginID ──┐        │
 │ Backlinks       [ON] │     │ off: 태그된   │                      │ 태깅    │
 │ Calendar        [ON] │     │ 등록물 제거    │  sidebar[] commands[] │        │
 └──────────────────────┘     │ +deactivate() │  statusItems[]  (id 태그 포함) │
                              │ on: activate  └──────────────▲───────────────┘
                              ▼ 재실행                        │ addSidebar/...
                       ┌─────────────┐    activate(host:)    │
                       │ Plugin 인스턴스│──────────────────────┘
                       └─────────────┘

 CalendarPlugin (ExtensionSDK + TemplateKit)
 ┌ Calendar ────────────┐
 │  ◀   2026년 6월   ▶ 오늘│   dots ← visible days × workspace.noteExists(
 │  일 월 화 수 목 금 토    │            PeriodicConfig.notePath(.daily, day))
 │      1∙ 2  3  4  5  6 │   click ──▶ planOpen(.daily, date) ──▶ open or
 │   7  8  9 10∙[11] …   │            create-from-template ──▶ openNote
 └──────────────────────┘   refresh ← indexDidUpdate (노트 생성/삭제 반영)
```

## 3. Components

### 3.1 SDK additions (`ExtensionSDK`)

```swift
public protocol Plugin {
    static var id: String { get }
    static var displayName: String { get }   // NEW (default: last id component)
    init()
    func activate(host: PluginHost)
    func deactivate()                        // NEW (default: no-op)
}
public extension Plugin {
    static var displayName: String { id.split(separator: ".").last.map(String.init) ?? id }
    func deactivate() {}
}
```
`SidebarContribution`, `Command`, `StatusItem` each gain an internal-use
`pluginID: String?` (defaulted nil so existing inits stay source-compatible —
the tagging happens in `PluginManager`'s add methods, not in plugin code).

### 3.2 `PluginManager` (AppCore)

```swift
public struct RegisteredPlugin: Identifiable {
    public let id: String          // Plugin.id
    public let displayName: String
    let instance: any Plugin
}
@Published public private(set) var plugins: [RegisteredPlugin]
public func isEnabled(_ id: String) -> Bool                 // UserDefaults, default true
public func setEnabled(_ id: String, _ on: Bool, host: ...) // live apply + persist
```
- `activate(_ plugins:, host:)` registers the roster, then activates only the
  enabled ones; during each `instance.activate(host:)` it sets
  `activatingPluginID = id` so `addSidebar/addCommand/addStatusItem` tag
  contributions.
- `setEnabled(id, false)`: remove tagged entries from `sidebar`, `commands`,
  `statusItems`; call `instance.deactivate()`.
- `setEnabled(id, true)`: re-run `instance.activate(host:)` (host kept `weak`;
  injected once from HanjiApp).
- PluginManager needs `UserDefaults` injection for tests (init parameter, like
  AppState).

### 3.3 Settings ▸ Plugins tab (`SettingsView`)

Third tab "Plugins": `ForEach(pluginManager.plugins)` rows — displayName,
id caption, `Toggle` bound to `isEnabled`/`setEnabled`. SettingsView gains
`@EnvironmentObject pluginManager` (inject in the Settings scene — it currently
only injects appState; missing injection would crash, so the plan must add it).

### 3.4 `CalendarGrid` (pure, inside CalendarPlugin target)

```swift
public struct CalendarGrid {
    public struct Day: Equatable { public let date: Date; public let day: Int; public let inMonth: Bool }
    public static func weeks(for month: Date, calendar: Calendar) -> [[Day]]   // 4–6 rows × 7
    public static func monthTitle(for month: Date, locale: Locale) -> String   // "2026년 6월"
}
```
Pure date math → fully unit-testable (leading offset, month lengths, leap
years, locale first-weekday).

### 3.5 `CalendarPlugin` (new target; deps: ExtensionSDK + TemplateKit)

- Registers sidebar view "Calendar" with the `[weak host]` factory pattern.
- View state: `displayedMonth: Date`, dot set `Set<Int>` (days with a daily
  note) recomputed when month changes or `indexDidUpdate` fires:
  `PeriodicConfig.load(vaultRoot:)` once per refresh, then
  `notePath(.daily, date: day)` + `workspace.noteExists` per visible in-month
  day.
- Click: same body as PeriodicNotesPlugin's command but with the clicked date —
  `planOpen(.daily, date: day, exists:, readTemplate:)` → `.open`/`.create+open`.
- Header: ◀ / month title / ▶ / "오늘"(jump to current month). Today gets an
  accent ring; dotted days a small dot under the number; out-of-month cells
  dimmed.

## 4. Testing

- `PluginToggle` (headless): activate roster with one disabled → its
  contributions absent; `setEnabled(false)` removes sidebar+command+status
  items of that plugin only; `setEnabled(true)` restores; persistence
  round-trips via injected UserDefaults suite.
- `CalendarGrid` (pure): June 2026 layout (starts Monday, 30 days), Feb 2024
  (leap), firstWeekday=1 vs 2 variants, 4/5/6-row months.
- `CalendarPlugin` loop: activate via real Host+AppState on a temp vault with
  a periodic config + one existing daily note → sidebar registered; the dot
  predicate (noteExists for that date's path) is true; clicking-path logic is
  the already-tested planOpen (no UI click simulation).
- E2E: toggle Backlinks off → `pm.sidebar` loses it → toggle on → returns.
- UI: build + screenshot (calendar grid + Plugins settings tab).

## 5. Out of scope

Dynamic/community plugin loading; renderer (①) toggle tracking; weekly-note
row in the calendar; mini heatmaps; per-plugin settings pages.
