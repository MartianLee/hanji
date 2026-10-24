import Foundation
import MarkdownCore
import AppCore

func linkTargetChecks() {
    let paths = ["Inbox/Plan.md", "Projects/Plan.md", "Projects/Roadmap.md", "한지.md"]
    expectEqual(LinkTarget.resolve("Plan", in: paths), "Inbox/Plan.md", "a shared name goes to the first note in file order")
    expectEqual(LinkTarget.resolve("projects/plan", in: paths), "Projects/Plan.md", "a path, ignoring case")
    expectEqual(LinkTarget.resolve("Roadmap.md#Goals", in: paths), "Projects/Roadmap.md", "`.md` and the anchor are ignored")
    expectEqual(LinkTarget.resolve("한지", in: paths), "한지.md", "Korean names")
    expectEqual(LinkTarget.resolve("Nope", in: paths), nil, "no such note")
}

func linkRewriteChecks() {
    let before = ["Archive/Roadmap.md", "Other.md", "Projects/Plan.md"]
    let after = ["Archive/Roadmap.md", "Other.md", "Projects/Roadmap.md"]
    let moves = ["Projects/Plan.md": "Projects/Roadmap.md"]
    func rw(_ t: String, _ m: [String: String] = moves, _ b: [String] = before, _ a: [String] = after) -> String {
        LinkRewrite.rewrite(t, moves: m, before: b, after: a).text
    }
    // Archive/Roadmap.md shares the new name, so a bare link goes to path form.
    expectEqual(rw("see [[Plan]]"), "see [[Projects/Roadmap]]", "a clash writes the path")
    let noClash = ["Projects/Roadmap.md", "Other.md"]
    let b2 = ["Projects/Plan.md", "Other.md"]
    expectEqual(rw("[[Plan]] [[plan#Goals|the plan]] ![[Plan]]", moves, b2, noClash),
                "[[Roadmap]] [[Roadmap#Goals|the plan]] ![[Roadmap]]", "bare names, anchor, alias, embed")
    expectEqual(rw("[[Projects/Plan]] [[Projects/Plan.md]]", moves, b2, noClash),
                "[[Projects/Roadmap]] [[Projects/Roadmap.md]]", "path form and a written .md are kept")
    expectEqual(rw("[t](Projects/Plan.md#x) [u](./Plan.md)", moves, b2, noClash),
                "[t](Projects/Roadmap.md#x) [u](./Roadmap.md)", "markdown links keep their form")
    expectEqual(rw("[[Other]] `[[Plan]]`\n```\n[[Plan]]\n```", moves, b2, noClash),
                "[[Other]] `[[Plan]]`\n```\n[[Plan]]\n```", "other notes and code are untouched")
    let moved = ["Projects/Plan.md": "Archive/Plan.md"]
    expectEqual(rw("[[Plan]] [[Projects/Plan]]", moved, b2, ["Archive/Plan.md", "Other.md"]),
                "[[Plan]] [[Archive/Plan]]", "a move leaves a bare name and fixes a path")
    expectEqual(rw("[a](Projects/Plan.md)", ["Projects/Plan.md": "My Notes/Plan.md"], b2, ["My Notes/Plan.md", "Other.md"]),
                "[a](My%20Notes/Plan.md)", "spaces in a new destination are %20")
    let shared = ["A/Plan.md", "B/Plan.md"]
    expectEqual(rw("[[Plan]]", ["B/Plan.md": "B/Next.md"], shared, ["A/Plan.md", "B/Next.md"]), "[[Plan]]",
                "a link to the other Plan isn't this rename's")
    expectEqual(LinkRewrite.rewrite("[[Plan]] and [[Plan]]", moves: moves, before: b2, after: noClash).count, 2, "count")
}

func renameRewriteChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-rrw-\(UUID().uuidString)")
    try? fm.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func put(_ p: String, _ t: String) { try? t.write(to: root.appendingPathComponent(p), atomically: true, encoding: .utf8) }
    func read(_ p: String) -> String? { try? String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
    put("Projects/Plan.md", "# Plan\nself: [[Plan]]"); put("Hub.md", "see [[Plan]] and [[Projects/Plan|p]]"); put("Other.md", "no links")
    let s = AppState(defaults: UserDefaults(suiteName: "mk-rrw-\(UUID().uuidString)")!)
    s.openVault(at: root)

    _ = try? s.rename(root.appendingPathComponent("Projects/Plan.md"), to: "Roadmap")
    expectEqual(read("Hub.md"), "see [[Roadmap]] and [[Projects/Roadmap|p]]", "links in other notes follow the rename")
    expectEqual(read("Projects/Roadmap.md"), "# Plan\nself: [[Roadmap]]", "and the note's links to itself")
    expectEqual(read("Other.md"), "no links", "notes without links are left alone")
    expectEqual(s.status, "Updated 3 links in 2 notes", "the status bar says what changed")

    put("Hub.md", "edited since")
    s.undoLastFileOperation()
    expect(fm.fileExists(atPath: root.appendingPathComponent("Projects/Plan.md").path), "undo moves the note back")
    expectEqual(read("Projects/Plan.md"), "# Plan\nself: [[Plan]]", "undo restores its text")
    expectEqual(read("Hub.md"), "edited since", "a note edited since keeps its newer text")
    s.notice = nil

    put("Hub.md", "see [[Projects/Plan]]")
    try? fm.createDirectory(at: root.appendingPathComponent("Archive"), withIntermediateDirectories: true)
    s.reloadTree()
    _ = try? s.move(root.appendingPathComponent("Projects"), into: root.appendingPathComponent("Archive"))
    expectEqual(read("Hub.md"), "see [[Archive/Projects/Plan]]", "moving a folder rewrites the paths under it")
}

func mentionChecks() {
    func found(_ name: String, _ text: String) -> [String] {
        Mentions.unlinked(of: name, in: text).map { (text as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
    }
    expectEqual(found("Plan", "The plan, a Plan; Planning, unplanned."), ["plan", "Plan"], "whole words, any case")
    expectEqual(found("한지", "한지는 종이다. 닥나무한지 아님"), ["한지"], "a particle may follow, a letter may not precede")
    expectEqual(found("Plan", "[[Plan]] `Plan` [p](Plan.md)\n```\nPlan\n```"), [], "not in links or code")
    expectEqual(found("Plan", "---\ntitle: Plan\n---\nPlan"), ["Plan"], "not in frontmatter")
}

func linkMentionChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hanji-lm-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func put(_ p: String, _ t: String) { try? t.write(to: root.appendingPathComponent(p), atomically: true, encoding: .utf8) }
    func read(_ p: String) -> String? { try? String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
    put("Plan.md", "x"); put("Hub.md", "the plan and Plan")
    let s = AppState(defaults: UserDefaults(suiteName: "mk-lm-\(UUID().uuidString)")!)
    s.openVault(at: root)
    expect(s.linkMention(sourcePath: "Hub.md", range: 4..<8, targetPath: "Plan.md"), "a mention is linked")
    expectEqual(read("Hub.md"), "the [[Plan|plan]] and Plan", "different case keeps the text as an alias")
    expect(!s.linkMention(sourcePath: "Hub.md", range: 4..<8, targetPath: "Plan.md"), "a stale range writes nothing")
    s.undoLastFileOperation()
    expectEqual(read("Hub.md"), "the plan and Plan", "⌥⌘Z undoes it")
    expect(s.linkMention(sourcePath: "Hub.md", range: 13..<17, targetPath: "Plan.md"), "same case")
    expectEqual(read("Hub.md"), "the plan and [[Plan]]", "is a plain link")
}
