import AppKit
import AppCore

/// Settings ▸ Appearance values: defaults keep today's look, choices persist,
/// and out-of-range stored values fall back to the default.
func appearanceSettingsChecks() {
    let suite = "mk-appearance-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let s1 = AppState(defaults: defaults)
    expectEqual(s1.theme, .system, "theme follows the system by default")
    expectEqual(s1.lineHeight, 1.3, "line height defaults to today's 1.3")
    expect(!s1.readableLineLength, "readable line length is off by default (today's full width)")
    expectEqual(s1.textFont, "", "text font is the system's by default")
    expectEqual(s1.codeFont, "", "code font is the system monospace by default")
    s1.theme = .dark; s1.lineHeight = 1.6; s1.readableLineLength = true
    s1.textFont = "Georgia"; s1.codeFont = "Menlo"
    let s2 = AppState(defaults: defaults)
    expectEqual(s2.theme, .dark, "theme persists")
    expectEqual(s2.lineHeight, 1.6, "line height persists")
    expect(s2.readableLineLength, "readable line length persists")
    expectEqual(s2.textFont, "Georgia", "text font persists")
    expectEqual(s2.codeFont, "Menlo", "code font persists")
    defaults.set(5.0, forKey: "io.hanji.lineHeight")
    expectEqual(AppState(defaults: defaults).lineHeight, 1.3, "an out-of-range stored line height falls back")
    expect(AppearanceTheme.system.appearanceName == nil, "system: no override")
    expectEqual(AppearanceTheme.light.appearanceName, .aqua, "light: Aqua")
    expectEqual(AppearanceTheme.dark.appearanceName, .darkAqua, "dark: Dark Aqua")
}
