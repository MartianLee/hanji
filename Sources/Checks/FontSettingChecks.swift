import AppKit
import Foundation
import AppCore
import MarkdownCore
import EditorEngine

func fontSettingChecks() {
    // Persisted appearance setting round-trips across instances.
    let suite = "mk-font-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let s1 = AppState(defaults: defaults)
    expectEqual(s1.fontSize, 15, "default font size is 15")
    s1.fontSize = 19
    let s2 = AppState(defaults: defaults)
    expectEqual(s2.fontSize, 19, "font size persists across instances")

    // The styler scales every role from the base size (verified through apply()).
    let original = LivePreviewStyler.baseFontSize
    defer { LivePreviewStyler.baseFontSize = original }
    let text = "# Title\nbody `c`"
    func fonts() -> (h1: CGFloat, body: CGFloat, code: CGFloat) {
        let storage = NSTextStorage(string: text)
        let deco = Decorator.decorations(spans: InlineTokenizer.spans(in: text), selection: 100..<100)
        LivePreviewStyler.apply(deco, to: storage)
        let h1 = (storage.attributes(at: 2, effectiveRange: nil)[.font] as? NSFont)?.pointSize ?? 0
        let body = (storage.attributes(at: 8, effectiveRange: nil)[.font] as? NSFont)?.pointSize ?? 0
        let code = (storage.attributes(at: 14, effectiveRange: nil)[.font] as? NSFont)?.pointSize ?? 0
        return (h1, body, code)
    }
    LivePreviewStyler.baseFontSize = 20
    let large = fonts()
    expectEqual(large.body, 20, "body follows base size")
    expect(large.h1 > 30, "H1 scales with base size")
    expectEqual(large.code, 19, "mono code is base − 1")
    LivePreviewStyler.baseFontSize = 15
    let normal = fonts()
    expect(normal.h1 < large.h1 && normal.body == 15, "smaller base → smaller everything")
}
