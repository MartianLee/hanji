import Foundation

/// `swift run Checks --changed`: run only the groups a change can reach, worked
/// out from the sources rather than kept as a list by hand.
///
/// - The change is the work tree against `--base` (default `HEAD`), untracked
///   files included.
/// - A changed module reaches every module that depends on it, per Package.swift.
/// - A check file is reached when it imports a reached module or is itself
///   changed; its groups are the functions it defines that main.swift registers.
/// - Groups marked `// slow` in main.swift run only with `--slow`; the rest of
///   the suite (and CI) still runs them every time.
/// - Package.swift or a shared helper (Expect.swift, ProbeSupport.swift)
///   changing reaches everything.
enum ChangedChecks {
    struct Selection {
        var groups: [String]
        var skippedSlow: [String]
        var notes: [String]
    }

    /// The repository root, from this file's own path (Sources/Checks/…).
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let sharedHelpers: Set<String> = ["Expect.swift", "ProbeSupport.swift"]

    static func select(base: String, includeSlow: Bool) -> Selection {
        select(changed: changedPaths(base: base), includeSlow: includeSlow)
    }

    /// The groups `changed` (paths relative to the root) reaches.
    static func select(changed: [String], includeSlow: Bool) -> Selection {
        let registry = registrations()
        var notes: [String] = []
        let everything = changed.contains { $0 == "Package.swift" || $0 == "Package.resolved" }
            || changed.contains { $0.hasPrefix("Sources/Checks/") && sharedHelpers.contains(($0 as NSString).lastPathComponent) }

        var modules = Set<String>()
        var checkFiles = Set<String>()
        for path in changed where path.hasPrefix("Sources/") {
            let parts = path.split(separator: "/")
            guard parts.count >= 3 else { continue }
            if parts[1] == "Checks" { checkFiles.insert(String(parts[2])) } else { modules.insert(String(parts[1])) }
        }
        if modules.contains("HanjiApp") {
            notes.append("HanjiApp changed: it has no headless checks — `swift build` and a look at the app cover it.")
        }
        let reached = dependents(of: modules)

        var functions = Set<String>()
        let checksDir = root.appendingPathComponent("Sources/Checks")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: checksDir.path)) ?? []
        for file in files where file.hasSuffix(".swift") && file != "main.swift" {
            guard let source = try? String(contentsOf: checksDir.appendingPathComponent(file), encoding: .utf8)
            else { continue }
            let imports = Set(matches(#"(?m)^import (\w+)"#, in: source).map { $0[0] })
            guard everything || checkFiles.contains(file) || !imports.isDisjoint(with: reached) else { continue }
            functions.formUnion(matches(#"(?m)^func (\w+)\(\)"#, in: source).map { $0[0] })
        }

        var selection = Selection(groups: [], skippedSlow: [], notes: notes)
        for entry in registry where functions.contains(entry.function) {
            if entry.slow && !includeSlow { selection.skippedSlow.append(entry.name) }
            else { selection.groups.append(entry.name) }
        }
        return selection
    }

    /// main.swift's `("Name", function),` lines, in order; `// slow` marks a slow one.
    private static func registrations() -> [(name: String, function: String, slow: Bool)] {
        let url = root.appendingPathComponent("Sources/Checks/main.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return source.split(separator: "\n").compactMap { line in
            guard let m = matches(#"\("(\w+)",\s*(\w+)\)"#, in: String(line)).first else { return nil }
            return (m[0], m[1], line.contains("// slow"))
        }
    }

    /// `modules` and every target that depends on one of them, directly or not.
    private static func dependents(of modules: Set<String>) -> Set<String> {
        let url = root.appendingPathComponent("Package.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return modules }
        var dependsOn: [String: Set<String>] = [:]
        for m in matches(#"\.(?:target|executableTarget)\(\s*name:\s*"(\w+)"(?:,\s*dependencies:\s*\[([^\]]*)\])?"#,
                         in: source) {
            dependsOn[m[0]] = Set(matches(#""(\w+)""#, in: m.count > 1 ? m[1] : "").map { $0[0] })
        }
        var reached = modules
        var grew = true
        while grew {
            grew = false
            for (target, deps) in dependsOn where !reached.contains(target) && !deps.isDisjoint(with: reached) {
                reached.insert(target)
                grew = true
            }
        }
        return reached
    }

    /// Paths (relative to the root) that differ from `base`, plus untracked files.
    private static func changedPaths(base: String) -> [String] {
        git(["diff", "--name-only", base]) + git(["ls-files", "--others", "--exclude-standard"])
    }

    private static func git(_ args: [String]) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root.path] + args
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Each match's capture groups (unmatched optional groups as "").
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
        }
    }
}

/// What `--changed` picks for a few kinds of change.
func changedChecksChecks() {
    func pick(_ paths: [String], slow: Bool = false) -> ChangedChecks.Selection {
        ChangedChecks.select(changed: paths, includeSlow: slow)
    }
    let core = pick(["Sources/MarkdownCore/ListContinuation.swift"])
    expect(core.groups.contains("ListRenumber"), "a MarkdownCore change runs its own checks")
    expect(core.groups.contains("EditorListRenumber"), "and the editor's, which build on it")
    expect(core.groups.contains("AppState"), "and the app model's")
    expect(core.skippedSlow.contains("IncrementalRestyle"), "slow groups wait for --slow")
    expect(pick(["Sources/MarkdownCore/Outline.swift"], slow: true).groups.contains("IncrementalRestyle"),
           "and run with it")

    let templates = pick(["Sources/TemplateKit/MomentFormat.swift"])
    expect(templates.groups.contains("MomentFormat"), "a TemplateKit change runs the template checks")
    expect(!templates.groups.contains("Tokenizer"), "but not the parser's")
    expect(!templates.groups.contains("EditorListRenumber"), "nor the editor's")

    let vault = pick(["Sources/VaultKit/Vault.swift"])
    expect(vault.groups.contains("Vault") && vault.groups.contains("AppState"),
           "a VaultKit change reaches the app model built on it")
    expect(!vault.groups.contains("EditorListRenumber"), "but not the editor, which doesn't use it")

    let app = pick(["Sources/HanjiApp/HanjiApp.swift"])
    expectEqual(app.groups, [], "the app target has no headless checks")
    expect(!app.notes.isEmpty, "which the run says")
    expectEqual(pick(["README.md", "docs/x.md"]).groups, [], "docs reach nothing")

    let file = pick(["Sources/Checks/OutlineChecks.swift"])
    expectEqual(Set(file.groups), ["Outline", "OutlineFocus", "EditorOutlineJump", "EditorInactivePaneJump"],
                "a changed check file runs its own groups")
    expect(pick(["Package.swift"]).groups.contains("CalendarGrid"), "Package.swift reaches everything")
    expect(pick(["Sources/Checks/Expect.swift"]).groups.contains("TemplaterConfig"), "so does the shared harness")
}
