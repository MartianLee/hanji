# Calendar Panel + Plugin Toggles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Obsidian-style live plugin on/off in Settings ▸ Plugins (existing plugins toggleable with zero plugin-code changes) and a Calendar right-sidebar panel whose days dot when a daily note exists and open-or-create on click.

**Architecture:** `PluginManager` keeps a plugin roster and an ownership ledger — while a plugin's `activate(host:)` runs, every `addSidebar/addCommand/addStatusItem` is recorded under that plugin's id; `setEnabled(id,false)` removes exactly those contributions and calls the new `deactivate()` hook, `setEnabled(id,true)` re-activates (host held weakly). `CalendarGrid` is pure date math (TDD); `CalendarPlugin` (ExtensionSDK+TemplateKit) renders the grid, dots via `PeriodicConfig.notePath(.daily)`+`workspace.noteExists`, clicks via the already-tested `planOpen`.

**Tech Stack:** Swift 5.10/SPM, SwiftUI, Combine, custom Checks runner. No new external deps.

**Spec:** `docs/2026-06-11-hanji-calendar-plugins-design.md` (flow diagram §2)

**Conventions:** tests in `Sources/Checks` (`expect`/`expectEqual`, register in main.swift, `swift run Checks <Group>`); red = build failure for new symbols; commits to main, real timestamps, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. READ real files before editing — line numbers drift.

**Spec note:** the spec sketches tagging via a `pluginID` field on contribution types; the chosen mechanism is an ownership ledger inside PluginManager (same observable behavior, zero SDK type changes) — this is the intended interpretation, not a deviation.

---

## File structure

- Modify `Sources/ExtensionSDK/ExtensionSDK.swift` — `Plugin.displayName` + `deactivate()` (extension defaults).
- Modify `Sources/AppCore/PluginManager.swift` — roster, ownership ledger, isEnabled/setEnabled, defaults injection.
- Modify `Sources/HanjiApp/SettingsView.swift` — Plugins tab.
- Modify `Sources/HanjiApp/HanjiApp.swift` — inject pluginManager into the Settings scene; register CalendarPlugin (Task 4).
- Create `Sources/CalendarPlugin/CalendarGrid.swift` — pure month math.
- Create `Sources/CalendarPlugin/CalendarPlugin.swift` — plugin + view.
- Modify `Package.swift` — CalendarPlugin target (+app/Checks deps).
- Tests: `Sources/Checks/PluginToggleChecks.swift`, `Sources/Checks/CalendarChecks.swift`, E2E step; registrations.

---

## Task 1: Plugin protocol hooks + PluginManager toggle engine

**Files:**
- Modify: `Sources/ExtensionSDK/ExtensionSDK.swift`
- Modify: `Sources/AppCore/PluginManager.swift`
- Create: `Sources/Checks/PluginToggleChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Failing test** — `Sources/Checks/PluginToggleChecks.swift`

```swift
import Foundation
import ExtensionSDK
import AppCore
import WordCountPlugin
import BacklinksPlugin
import MKSearchKit

func pluginToggleChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-tg-\(UUID().uuidString)")
    try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "# A".write(to: vault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

    let suite = "mk-tg-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let appState = AppState(defaults: UserDefaults(suiteName: "mk-tg2-\(UUID().uuidString)")!)
    appState.openVault(at: vault)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    let pm = PluginManager(defaults: defaults)
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([WordCountPlugin(), BacklinksPlugin()], host: host)

    expectEqual(pm.plugins.map(\.id), ["io.hanji.wordcount", "io.hanji.backlinks"], "roster registered")
    expectEqual(pm.plugins.first?.displayName, "wordcount", "default displayName = last id component")
    expectEqual(pm.statusItems.count, 1, "wordcount status item active")
    expectEqual(pm.sidebar.count, 1, "backlinks sidebar active")
    expect(pm.isEnabled("io.hanji.backlinks"), "enabled by default")

    // Live disable removes exactly that plugin's contributions.
    pm.setEnabled("io.hanji.backlinks", false)
    expectEqual(pm.sidebar.count, 0, "disable removes its sidebar view")
    expectEqual(pm.statusItems.count, 1, "other plugin untouched")
    expect(!pm.isEnabled("io.hanji.backlinks"), "state persisted")

    // Live re-enable restores by re-running activate.
    pm.setEnabled("io.hanji.backlinks", true)
    expectEqual(pm.sidebar.count, 1, "enable restores the sidebar view")

    // Disabled state survives a relaunch: a fresh manager skips activation.
    pm.setEnabled("io.hanji.wordcount", false)
    let pm2 = PluginManager(defaults: defaults)
    let host2 = Host(appState: appState, pluginManager: pm2)
    pm2.activate([WordCountPlugin(), BacklinksPlugin()], host: host2)
    expectEqual(pm2.statusItems.count, 0, "disabled plugin not activated on launch")
    expectEqual(pm2.sidebar.count, 1, "enabled plugin still activates")
}
```

- [ ] **Step 2: Register** — `("PluginToggle", pluginToggleChecks),` in `Sources/Checks/main.swift` (before E2E).

- [ ] **Step 3: Red** — `swift run Checks PluginToggle` → build failure (`PluginManager` has no `plugins`/`isEnabled`).

- [ ] **Step 4: SDK hooks** — in `Sources/ExtensionSDK/ExtensionSDK.swift`, change the `Plugin` protocol to:

```swift
/// A compile-time-loaded extension.
public protocol Plugin {
    static var id: String { get }
    /// Shown in Settings ▸ Plugins (defaults to the last id component).
    static var displayName: String { get }
    init()
    func activate(host: PluginHost)
    /// Called when the user toggles the plugin off (release resources here).
    func deactivate()
}

public extension Plugin {
    static var displayName: String { id.split(separator: ".").last.map(String.init) ?? id }
    func deactivate() {}
}
```

- [ ] **Step 5: PluginManager engine** — replace `Sources/AppCore/PluginManager.swift` with:

```swift
import Foundation
import ExtensionSDK

/// One entry in the plugin roster (Settings ▸ Plugins).
public struct RegisteredPlugin: Identifiable {
    public let id: String
    public let displayName: String
    let instance: any Plugin
}

public final class PluginManager: ObservableObject {
    @Published public private(set) var sidebar: [SidebarContribution] = []
    @Published public private(set) var commands: [Command] = []
    @Published public private(set) var statusItems: [StatusItem] = []
    @Published public private(set) var plugins: [RegisteredPlugin] = []

    /// Which contributions each plugin registered, so a toggle-off removes
    /// exactly those. Tagged automatically while `activate(host:)` runs.
    private struct Ownership { var sidebarIDs: [String] = []; var commandIDs: [String] = []; var statusIDs: [String] = [] }
    private var ownership: [String: Ownership] = [:]
    private var activatingPluginID: String?
    private weak var host: PluginHost?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Register the roster and activate the enabled plugins.
    public func activate(_ list: [any Plugin], host: PluginHost) {
        self.host = host
        for plugin in list {
            let id = type(of: plugin).id
            plugins.append(RegisteredPlugin(id: id, displayName: type(of: plugin).displayName,
                                            instance: plugin))
            if isEnabled(id) { runActivate(plugin, id: id, host: host) }
        }
    }

    // MARK: - Toggles (Obsidian-style, applied live)

    public func isEnabled(_ id: String) -> Bool {
        defaults.object(forKey: Self.key(id)) as? Bool ?? true
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        defaults.set(on, forKey: Self.key(id))
        guard let registered = plugins.first(where: { $0.id == id }) else { return }
        if on {
            guard let host, ownership[id] == nil else { return }   // already active or no host
            runActivate(registered.instance, id: id, host: host)
        } else {
            guard let owned = ownership[id] else { return }        // already inactive
            sidebar.removeAll { owned.sidebarIDs.contains($0.id) }
            commands.removeAll { owned.commandIDs.contains($0.id) }
            statusItems.removeAll { owned.statusIDs.contains($0.id) }
            ownership[id] = nil
            registered.instance.deactivate()
        }
    }

    private func runActivate(_ plugin: any Plugin, id: String, host: PluginHost) {
        activatingPluginID = id
        ownership[id] = Ownership()
        plugin.activate(host: host)
        activatingPluginID = nil
    }

    private static func key(_ id: String) -> String { "io.hanji.plugin.\(id).enabled" }

    // MARK: - Registration (called by Host; tagged to the activating plugin)

    func addSidebar(_ contribution: SidebarContribution) {
        sidebar.append(contribution)
        if let pid = activatingPluginID { ownership[pid]?.sidebarIDs.append(contribution.id) }
    }

    func addCommand(_ command: Command) {
        commands.append(command)
        if let pid = activatingPluginID { ownership[pid]?.commandIDs.append(command.id) }
    }

    func addStatusItem(_ item: StatusItem) {
        statusItems.append(item)
        if let pid = activatingPluginID { ownership[pid]?.statusIDs.append(item.id) }
    }
}
```
Note: the shell's own `file.moveTo` command is registered OUTSIDE any plugin activation (`activatingPluginID == nil`) so it is never owned/removed — correct.

- [ ] **Step 6: Green** — `swift run Checks PluginToggle` ✅, then `swift run Checks PluginLoop && swift run Checks CommandRegistry2 && swift run Checks BacklinksPlugin` ✅ (signature `activate(_:host:)` unchanged), then full `swift run Checks`.

- [ ] **Step 7: Commit**

```bash
git add Sources/ExtensionSDK/ExtensionSDK.swift Sources/AppCore/PluginManager.swift Sources/Checks/PluginToggleChecks.swift Sources/Checks/main.swift
git commit -m "feat(plugins): live enable/disable engine with per-plugin contribution ownership" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Settings ▸ Plugins tab + E2E toggle step

**Files:**
- Modify: `Sources/HanjiApp/SettingsView.swift`
- Modify: `Sources/HanjiApp/HanjiApp.swift`
- Modify: `Sources/Checks/E2EChecks.swift`

- [ ] **Step 1: Plugins tab** — in `SettingsView.swift`, add `@EnvironmentObject var pluginManager: PluginManager` next to `appState`. Add a third tab to the `TabView`:

```swift
            pluginsTab
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
```
And the tab body:
```swift
    /// Obsidian-style plugin toggles (applied live).
    private var pluginsTab: some View {
        Form {
            ForEach(pluginManager.plugins) { plugin in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plugin.displayName)
                        Text(plugin.id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { pluginManager.isEnabled(plugin.id) },
                        set: { pluginManager.setEnabled(plugin.id, $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(20)
    }
```

- [ ] **Step 2: Inject pluginManager into the Settings scene** — in `HanjiApp.swift` (MISSING THIS CRASHES AT RUNTIME):

```swift
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(pluginManager)
        }
```

- [ ] **Step 3: E2E toggle step** — in `Sources/Checks/E2EChecks.swift`, right after the `pm.activate(...)` line, insert:

```swift
    // 0b. Plugin toggles: disabling removes the plugin's commands, enabling restores.
    let periodicID = "io.hanji.periodicnotes"
    let commandCountBefore = pm.commands.count
    pm.setEnabled(periodicID, false)
    expectEqual(pm.commands.count, commandCountBefore - 3, "E2E: disable drops the 3 periodic commands")
    pm.setEnabled(periodicID, true)
    expectEqual(pm.commands.count, commandCountBefore, "E2E: enable restores them")
```
⚠️ The E2E constructs `PluginManager()` with `.standard` defaults — change that construction to an isolated suite so toggling doesn't pollute real settings:
```swift
    let pm = PluginManager(defaults: UserDefaults(suiteName: "mk-e2e-pm-\(UUID().uuidString)")!)
```

- [ ] **Step 4: Verify** — `swift build` ✅, `swift run Checks E2E` ✅, full `swift run Checks` ✅.

- [ ] **Step 5: Commit**

```bash
git add Sources/HanjiApp/SettingsView.swift Sources/HanjiApp/HanjiApp.swift Sources/Checks/E2EChecks.swift
git commit -m "feat(settings): Plugins tab with live toggles (+ E2E toggle step)" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: CalendarGrid (pure month math)

**Files:**
- Modify: `Package.swift` (new target now so the grid file compiles)
- Create: `Sources/CalendarPlugin/CalendarGrid.swift`
- Create: `Sources/Checks/CalendarChecks.swift`
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Package.swift** — add target and wire Checks:
```swift
        .target(name: "CalendarPlugin", dependencies: ["ExtensionSDK", "TemplateKit"]),
```
Append `"CalendarPlugin"` to the Checks deps (HanjiApp dep comes in Task 4).

- [ ] **Step 2: Failing test** — `Sources/Checks/CalendarChecks.swift`

```swift
import Foundation
import CalendarPlugin

func calendarGridChecks() {
    var sunCal = Calendar(identifier: .gregorian)
    sunCal.timeZone = TimeZone(identifier: "UTC")!
    sunCal.firstWeekday = 1   // Sunday
    var monCal = sunCal
    monCal.firstWeekday = 2   // Monday

    func date(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // June 2026 starts on a Monday and has 30 days.
    let june = CalendarGrid.weeks(for: date(2026, 6, 15, sunCal), calendar: sunCal)
    expect(june.count == 5, "June 2026 fits 5 rows (Sunday start)")
    expect(june.allSatisfy { $0.count == 7 }, "every row has 7 days")
    expectEqual(june[0][0].inMonth, false, "leading May day padded")
    expectEqual(june[0][1].day, 1, "June 1 in the second cell (Monday)")
    expect(june[0][1].inMonth, "June 1 is in-month")
    expectEqual(june.flatMap { $0 }.filter(\.inMonth).count, 30, "30 in-month days")

    // Monday-start calendar: June 1 lands in the first cell.
    let juneMon = CalendarGrid.weeks(for: date(2026, 6, 15, monCal), calendar: monCal)
    expectEqual(juneMon[0][0].day, 1, "Monday-start puts June 1 first")
    expect(juneMon[0][0].inMonth, "first cell in-month")

    // February 2024: leap year, 29 days.
    let feb = CalendarGrid.weeks(for: date(2024, 2, 10, sunCal), calendar: sunCal)
    expectEqual(feb.flatMap { $0 }.filter(\.inMonth).count, 29, "leap February has 29 days")

    // Month title is locale-aware.
    let title = CalendarGrid.monthTitle(for: date(2026, 6, 15, sunCal), locale: Locale(identifier: "ko_KR"))
    expect(title.contains("2026") && title.contains("6"), "Korean month title has year+month")
}
```

- [ ] **Step 3: Register** — `("CalendarGrid", calendarGridChecks),` in main.swift.

- [ ] **Step 4: Red** — `swift run Checks CalendarGrid` → `no such module 'CalendarPlugin'`.

- [ ] **Step 5: Implement `Sources/CalendarPlugin/CalendarGrid.swift`**

```swift
import Foundation

/// Pure month-grid math for the calendar panel: 4–6 rows of 7 days, padded
/// with the neighboring months' days (marked `inMonth == false`).
public enum CalendarGrid {
    public struct Day: Equatable {
        public let date: Date
        public let day: Int        // day-of-month number to display
        public let inMonth: Bool
        public init(date: Date, day: Int, inMonth: Bool) {
            self.date = date
            self.day = day
            self.inMonth = inMonth
        }
    }

    public static func weeks(for month: Date, calendar: Calendar) -> [[Day]] {
        let comps = calendar.dateComponents([.year, .month], from: month)
        guard let firstOfMonth = calendar.date(from: comps),
              let dayCount = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count
        else { return [] }

        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)   // 1 = Sunday
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var days: [Day] = []
        for i in 0..<leading {
            guard let d = calendar.date(byAdding: .day, value: -(leading - i), to: firstOfMonth) else { continue }
            days.append(Day(date: d, day: calendar.component(.day, from: d), inMonth: false))
        }
        for n in 0..<dayCount {
            guard let d = calendar.date(byAdding: .day, value: n, to: firstOfMonth) else { continue }
            days.append(Day(date: d, day: n + 1, inMonth: true))
        }
        while days.count % 7 != 0 {
            guard let last = days.last?.date,
                  let d = calendar.date(byAdding: .day, value: 1, to: last) else { break }
            days.append(Day(date: d, day: calendar.component(.day, from: d), inMonth: false))
        }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    public static func monthTitle(for month: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: month)
    }
}
```

- [ ] **Step 6: Green** — `swift run Checks CalendarGrid` → ✅ (10 assertions).

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/CalendarPlugin/CalendarGrid.swift Sources/Checks/CalendarChecks.swift Sources/Checks/main.swift
git commit -m "feat(calendar): pure month-grid math (locale week start, padding, leap years)" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: CalendarPlugin (panel + registration)

**Files:**
- Create: `Sources/CalendarPlugin/CalendarPlugin.swift`
- Modify: `Package.swift` (HanjiApp deps + `"CalendarPlugin"`)
- Modify: `Sources/HanjiApp/HanjiApp.swift`
- Modify: `Sources/Checks/CalendarChecks.swift` (append group)
- Modify: `Sources/Checks/main.swift`

- [ ] **Step 1: Failing test** — append to `Sources/Checks/CalendarChecks.swift` (add the needed imports at top: `ExtensionSDK`, `AppCore`, `TemplateKit`, `MKSearchKit`):

```swift
func calendarPluginChecks() {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("mk-cal-\(UUID().uuidString)")
    let pluginDir = vault.appendingPathComponent(".obsidian/plugins/periodic-notes")
    try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: vault.appendingPathComponent("Daily"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: vault) }
    try? "{ \"daily\": { \"folder\": \"Daily\", \"format\": \"YYYY-MM-DD\" } }"
        .write(to: pluginDir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
    try? "# today".write(to: vault.appendingPathComponent("Daily/2026-06-10.md"), atomically: true, encoding: .utf8)

    let appState = AppState(defaults: UserDefaults(suiteName: "mk-cal-\(UUID().uuidString)")!)
    appState.openVault(at: vault)
    defer { try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: vault)) }
    let pm = PluginManager(defaults: UserDefaults(suiteName: "mk-calpm-\(UUID().uuidString)")!)
    let host = Host(appState: appState, pluginManager: pm)
    pm.activate([CalendarPlugin()], host: host)

    expectEqual(pm.sidebar.count, 1, "calendar sidebar registered")
    expectEqual(pm.sidebar.first?.title ?? "", "Calendar", "panel title")
    expectEqual(CalendarPlugin.displayName, "Calendar", "display name override")
    _ = pm.sidebar.first?.makeView()

    // The dot predicate the view uses: daily note exists for 2026-06-10, not for 06-11.
    let cfg = PeriodicConfig.load(vaultRoot: vault)
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    let d10 = cal.date(from: DateComponents(year: 2026, month: 6, day: 10))!
    let d11 = cal.date(from: DateComponents(year: 2026, month: 6, day: 11))!
    expect(host.workspace.noteExists(relativePath: cfg.notePath(.daily, date: d10)), "dot day detected")
    expect(!host.workspace.noteExists(relativePath: cfg.notePath(.daily, date: d11)), "non-dot day clean")
}
```
⚠️ Timezone note: `cfg.notePath(.daily, date:)` defaults to `.current` timezone — build the test dates with `.current` too (as above) so the formatted name matches the fixture.

- [ ] **Step 2: Register** — `("CalendarPlugin", calendarPluginChecks),` in main.swift.

- [ ] **Step 3: Red** — `swift run Checks CalendarPlugin` → `cannot find 'CalendarPlugin' in scope`.

- [ ] **Step 4: Implement `Sources/CalendarPlugin/CalendarPlugin.swift`**

```swift
import SwiftUI
import Combine
import ExtensionSDK
import TemplateKit

/// First-party calendar panel: month grid with dots on days that have a daily
/// note; clicking a day opens-or-creates it through the periodic-notes pipeline.
public struct CalendarPlugin: Plugin {
    public static let id = "io.hanji.calendar"
    public static let displayName = "Calendar"
    public init() {}

    public func activate(host: PluginHost) {
        host.ui.addSidebarView(id: "calendar", title: "Calendar") { [weak host] in
            guard let host else { return AnyView(EmptyView()) }
            return AnyView(CalendarView(workspace: host.workspace,
                                        indexUpdates: host.query.indexDidUpdate))
        }
    }
}

struct CalendarView: View {
    let workspace: WorkspaceActions
    let indexUpdates: AnyPublisher<Void, Never>

    @State private var month = Date()
    @State private var dottedDays: Set<Int> = []

    private var calendar: Calendar { Calendar.current }
    private var weeks: [[CalendarGrid.Day]] { CalendarGrid.weeks(for: month, calendar: calendar) }

    var body: some View {
        VStack(spacing: 6) {
            header
            weekdayRow
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                    }
                }
            }
        }
        .onAppear { refreshDots() }
        .onChange(of: month) { _, _ in refreshDots() }
        .onReceive(indexUpdates) { refreshDots() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Text(CalendarGrid.monthTitle(for: month, locale: Locale.current))
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            Button("오늘") { month = Date() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        }
    }

    private var weekdayRow: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let rotated = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(rotated, id: \.self) { s in
                Text(s).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func dayCell(_ day: CalendarGrid.Day) -> some View {
        let isToday = calendar.isDateInToday(day.date)
        Button { open(day.date) } label: {
            VStack(spacing: 1) {
                Text("\(day.day)")
                    .font(.caption)
                    .frame(width: 22, height: 18)
                    .background(isToday ? Color.accentColor.opacity(0.25) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Circle()
                    .fill(day.inMonth && dottedDays.contains(day.day) ? Color.accentColor : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .opacity(day.inMonth ? 1 : 0.3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shift(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: month) { month = next }
    }

    /// Days of the displayed month that already have a daily note.
    private func refreshDots() {
        guard let root = workspace.vaultRoot else { dottedDays = []; return }
        let cfg = PeriodicConfig.load(vaultRoot: root)
        var dots: Set<Int> = []
        for day in weeks.flatMap({ $0 }) where day.inMonth {
            if workspace.noteExists(relativePath: cfg.notePath(.daily, date: day.date)) {
                dots.insert(day.day)
            }
        }
        dottedDays = dots
    }

    /// Open-or-create the day's daily note (same pipeline as the ⌘P command).
    private func open(_ date: Date) {
        guard let root = workspace.vaultRoot else { return }
        let cfg = PeriodicConfig.load(vaultRoot: root)
        let action = cfg.planOpen(.daily, date: date,
                                  exists: { workspace.noteExists(relativePath: $0) },
                                  readTemplate: { workspace.readNote(relativePath: $0) })
        switch action {
        case .open(let path):
            workspace.openNote(relativePath: path)
        case .create(let path, let text, let cursor):
            workspace.createNote(relativePath: path, text: text, cursorOffset: cursor)
            workspace.openNote(relativePath: path)
        }
    }
}
```

- [ ] **Step 5: Wire the app** — `Package.swift`: append `"CalendarPlugin"` to HanjiApp deps. `HanjiApp.swift`: `import CalendarPlugin`, plugins array becomes:
```swift
                    let plugins: [Plugin] = [WordCountPlugin(), PeriodicNotesPlugin(), TemplaterPlugin(), BacklinksPlugin(), CalendarPlugin()]
```

- [ ] **Step 6: Green** — `swift run Checks CalendarPlugin` ✅, full `swift run Checks` ✅, `swift build` ✅.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/CalendarPlugin Sources/HanjiApp/HanjiApp.swift Sources/Checks/CalendarChecks.swift Sources/Checks/main.swift
git commit -m "feat(calendar): month panel with daily-note dots and open-or-create days" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: README + full verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: README** — add to the status list:
```markdown
- **Calendar panel** — right-sidebar month view; days with a daily note are
  dotted, clicking any day opens-or-creates it from your template
- **Plugin toggles** — Settings ▸ Plugins switches any first-party plugin on or
  off live, Obsidian-style (persisted per plugin)
```

- [ ] **Step 2: Verify** — full `swift run Checks`; `./Scripts/e2e.sh`; the controller does the screenshot pass (calendar grid + Plugins tab + toggle-off behavior).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: calendar + plugin toggles in README" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-review (vs spec)

- §3.1 Plugin hooks → Task 1 Step 4. §3.2 PluginManager (roster/ledger/isEnabled/setEnabled/weak host/defaults injection) → Task 1 Step 5 (ledger instead of field-tagging — declared in the header note). §3.3 Settings tab + scene injection (crash guard) → Task 2. §3.4 CalendarGrid pure + tests → Task 3. §3.5 CalendarPlugin (weak-host factory, dots, planOpen click, ◀▶오늘, today ring, dimmed out-month) → Task 4. §4 tests (PluginToggle incl. persistence; CalendarGrid leap/locale; CalendarPlugin loop + dot predicate; E2E toggle) → Tasks 1–4. §5 exclusions respected.
- Type consistency: `RegisteredPlugin{id,displayName,instance}`, `isEnabled(_:)/setEnabled(_:_:)`, `CalendarGrid.Day{date,day,inMonth}` / `weeks(for:calendar:)` / `monthTitle(for:locale:)`, `CalendarPlugin.displayName` — consistent.
- Risks pinned: E2E PluginManager must switch to an isolated defaults suite (Task 2 Step 3 ⚠️); timezone alignment in the dot test (Task 4 Step 1 ⚠️); `file.moveTo` shell command unowned by design (Task 1 note).
