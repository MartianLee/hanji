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
    expectEqual(TemplateEngine.render("<% tp.file.creation_date(\"YYYY-MM-DD\") %>", ctx).text,
                "2026-06-09", "tp.file.creation_date with format")
    expectEqual(TemplateEngine.render("<% tp.unknown.fn() %>!", ctx).text, "!", "unknown call → empty")
    expectEqual(TemplateEngine.render("a<%* tp.whatever() %>b", ctx).text, "ab", "exec block stripped")

    // Obsidian core-template syntax ({{...}}), used by core Daily/Templates.
    expectEqual(TemplateEngine.render("Created: {{date:YYYY-MM-DD}}", ctx).text,
                "Created: 2026-06-09", "core {{date:fmt}}")
    expectEqual(TemplateEngine.render("{{date}}", ctx).text, "2026-06-09", "core {{date}} default format")
    expectEqual(TemplateEngine.render("{{time}}", ctx).text, "00:00", "core {{time}} default format")
    expectEqual(TemplateEngine.render("{{title}}", ctx).text, "My Note", "core {{title}}")
    expectEqual(TemplateEngine.render("{{unknown}}", ctx).text, "{{unknown}}", "unknown core token stays raw")
    let mixed = TemplateEngine.render("{{date}} <% tp.file.cursor() %>X", ctx)
    expectEqual(mixed.text, "2026-06-09 X", "core + templater mix")
    expectEqual(mixed.cursorOffset, 11, "cursor offset counts substituted core tokens")

    let cursor = TemplateEngine.render("AB<% tp.file.cursor() %>CD", ctx)
    expectEqual(cursor.text, "ABCD", "cursor token removed from text")
    expectEqual(cursor.cursorOffset, 2, "cursor offset recorded (UTF-16)")
    expect(TemplateEngine.render("no cursor", ctx).cursorOffset == nil, "no cursor → nil offset")
}
