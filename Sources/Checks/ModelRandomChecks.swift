import Foundation
import AppCore
import VaultKit
import MKSearchKit

// Model-based random testing of AppState's tab/pane/file model.
//
// Every note carries an identity header `@id:N`; every keystroke burst appends a
// unique token `⟦N.k⟧`. After each step the harness checks that no token typed
// by the user has vanished (except through a deliberate discard: delete, close
// without saving, reload-from-disk, an external write/delete), that no file on
// disk holds another note's tokens, and structural invariants.
//
// Run: `swift run Checks ProbeRandom` (env PROBE_SEEDS=N, PROBE_STEPS=N,
// PROBE_WATCH=fast|slow, PROBE_SKIP=op,op to disable ops).

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}

enum ROp: String, CaseIterable {
    case open, type, wait, switchTab, split, focus, moveTab, closeTab, pin, save
    case renameFile, renameFolder, moveFile, delete, undo, newNote
    case extWrite, extDelete, extRename, reload
    case replace, resolveReload, resolveMine, restoreMissing, closeMissing
    case switchVault, template
}

struct RStep: CustomStringConvertible {
    let op: ROp
    let a: Int, b: Int, c: Int
    var description: String { "\(op.rawValue)(\(a),\(b),\(c))" }
}

final class RandomModel {
    let p: ProbeVault
    let other: URL
    var s: AppState { p.s }
    var nextNoteID = 100
    var tokenSeq = 0
    var liveTokens = Set<String>()
    var log: [String] = []
    let fastWatcher: Bool
    var failure: String?

    static let names = ["Alpha", "b e t a", "한글", "emoji 🙂", "#hash", "%pct 20", "UPPER", "upper", "Notes", "x.MD"]

    init(fastWatcher: Bool) {
        self.fastWatcher = fastWatcher
        p = ProbeVault("rand", files: [
            "A.md": "@id:1\nseed a",
            "B.md": "@id:2\nseed b",
            "Notes/C.md": "@id:3\nseed c",
            "Notes/Deep/D.md": "@id:4\nseed d",
            "Other/E.md": "@id:5\nseed e",
        ], autosave: 0.02)
        other = FileManager.default.temporaryDirectory.appendingPathComponent("hanji-probe-rand-other-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    }
    func cleanup() { p.cleanup(); try? FileManager.default.removeItem(at: other) }

    // MARK: helpers
    func allDiskFiles() -> [(URL, String)] {
        guard let en = FileManager.default.enumerator(at: p.root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [(URL, String)] = []
        for case let u as URL in en {
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
               let t = try? String(contentsOf: u, encoding: .utf8) { out.append((u, t)) }
        }
        return out
    }
    static func tokens(in text: String) -> [String] {
        var out: [String] = []
        var rest = text[...]
        while let o = rest.range(of: "⟦"), let c = rest[o.upperBound...].range(of: "⟧") {
            out.append(String(rest[o.lowerBound..<c.upperBound])); rest = rest[c.upperBound...]
        }
        return out
    }
    static func header(_ text: String) -> String? {
        guard text.hasPrefix("@id:") else { return nil }
        return String(text.dropFirst(4).prefix { $0 != "\n" })
    }
    /// Tokens that are safe: on disk, or in a buffer that still counts as unsaved
    /// (a clean buffer is only a copy of some past disk state).
    func foundTokens() -> Set<String> {
        var texts = allDiskFiles().map(\.1)
        if s.isDirty { texts.append(s.activeText) }
        for pane in s.panes {
            for t in pane.tabs where !(pane.id == s.activePaneID && t.id == pane.activeTabID) {
                if t.isDirty { texts.append(t.text) }
            }
        }
        return Set(texts.flatMap(Self.tokens))
    }
    func mdFiles() -> [MarkdownFile] { s.files }
    func folders() -> [URL] {
        var out: [URL] = [p.root]
        func walk(_ n: [FileNode]) { for x in n where x.isDirectory { out.append(x.url); walk(x.children ?? []) } }
        walk(s.tree)
        return out
    }
    func rel(_ u: URL) -> String {
        let r = p.root.standardizedFileURL.path + "/"
        let x = u.standardizedFileURL.path
        return x.hasPrefix(r) ? String(x.dropFirst(r.count)) : x
    }

    let avoidKnown = ProcessInfo.processInfo.environment["PROBE_AVOID_KNOWN"] != nil
    /// Known bug P1: a background pane whose only tab's file vanishes collapses
    /// and clobbers the live buffer.
    func soleTabOfBackgroundPane(_ u: URL) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return true }
        return s.panes.contains { $0.id != s.activePaneID && $0.tabs.count == 1
            && $0.tabs[0].file.url.standardizedFileURL.path == u.standardizedFileURL.path }
    }

    // MARK: step
    /// Returns whether the step is a deliberate discard.
    func apply(_ st: RStep) -> Bool {
        let fm = FileManager.default
        switch st.op {
        case .open:
            let fs = mdFiles(); guard !fs.isEmpty else { return false }
            let f = fs[st.a % fs.count]
            if avoidKnown && s.panes.contains(where: { $0.id != s.activePaneID && $0.tabs.contains { $0.file.url.standardizedFileURL.path == f.url.standardizedFileURL.path } }) { return false }
            log.append("open \(rel(f.url))"); s.open(f)
        case .type:
            guard s.selectedFile != nil else { return false }
            var t = s.activeText
            if Self.header(t) == nil { nextNoteID += 1; t = "@id:\(nextNoteID)\n" + t }
            let id = Self.header(t)!
            tokenSeq += 1
            let tok = "⟦\(id).\(tokenSeq)⟧"
            t += " " + tok
            liveTokens.insert(tok)
            log.append("type \(tok) into \(s.selectedFile!.name)")
            s.activeText = t
        case .wait:
            log.append("wait (autosave)"); p.pump(0.06)
        case .switchTab:
            let ts = s.tabs; guard !ts.isEmpty else { return false }
            let t = ts[st.a % ts.count]; log.append("switchTab \(t.file.name)"); s.switchTab(t.id)
        case .split:
            log.append("splitRight"); s.splitRight()
        case .focus:
            guard s.panes.count > 1 else { return false }
            let pn = s.panes[st.a % s.panes.count]; log.append("focusPane \(s.panes.firstIndex { $0.id == pn.id }!)"); s.focusPane(pn.id)
        case .moveTab:
            let all = s.panes.flatMap(\.tabs); guard !all.isEmpty else { return false }
            let t = all[st.a % all.count]; let side: AppState.PaneSide = st.b % 2 == 0 ? .left : .right
            if avoidKnown, let si = s.panes.firstIndex(where: { $0.tabs.contains { $0.id == t.id } }) {
                let ti = side == .right ? si + 1 : si - 1
                if ti >= 0 && ti < s.panes.count && s.panes[ti].tabs.contains(where: { $0.file.url.standardizedFileURL == t.file.url.standardizedFileURL }) { return false }
            }
            log.append("moveTabToSide \(t.file.name) \(side)"); s.moveTabToSide(t.id, side)
        case .closeTab:
            let ts = s.tabs; guard !ts.isEmpty else { return false }
            let t = ts[st.a % ts.count]; log.append("closeTab \(t.file.name)"); s.closeTab(t.id)
        case .pin:
            let all = s.panes.flatMap(\.tabs); guard !all.isEmpty else { return false }
            let t = all[st.a % all.count]; log.append("togglePin \(t.file.name)"); s.togglePin(t.id)
        case .save:
            log.append("save"); s.save()
        case .renameFile:
            let fs = mdFiles(); guard !fs.isEmpty else { return false }
            let f = fs[st.a % fs.count]; let n = Self.names[st.b % Self.names.count]
            log.append("rename \(rel(f.url)) → \(n)")
            do { _ = try s.rename(f.url, to: n) } catch { log.append("  threw \(error)") }
        case .renameFolder:
            let ds = folders().dropFirst(); guard !ds.isEmpty else { return false }
            let d = Array(ds)[st.a % ds.count]; let n = Self.names[st.b % Self.names.count]
            log.append("renameFolder \(rel(d)) → \(n)")
            do { _ = try s.rename(d, to: n) } catch { log.append("  threw \(error)") }
        case .moveFile:
            let items = mdFiles().map(\.url) + Array(folders().dropFirst()); guard !items.isEmpty else { return false }
            let x = items[st.a % items.count]; let ds = folders(); let d = ds[st.b % ds.count]
            log.append("move \(rel(x)) into \(rel(d))")
            do { _ = try s.move(x, into: d) } catch { log.append("  threw \(error)") }
        case .delete:
            let items = mdFiles().map(\.url) + Array(folders().dropFirst()); guard !items.isEmpty else { return false }
            let x = items[st.a % items.count]; log.append("delete \(rel(x))"); s.delete(x)
            return true
        case .undo:
            let last = s.fileOperations.last
            log.append("undo \(last.map { "\($0)" } ?? "nil")")
            s.undoLastFileOperation()
            if case .renamed? = last { return false }
            if case .moved? = last { return false }
            if case .replaced? = last { return false }
            return true
        case .newNote:
            let ds = folders(); let d = ds[st.a % ds.count]
            log.append("newNote in \(rel(d))"); _ = s.newNote(inFolder: d == p.root ? nil : d)
        case .extWrite:
            let fs = mdFiles(); guard !fs.isEmpty else { return false }
            let f = fs[st.a % fs.count]
            let cur = (try? String(contentsOf: f.url, encoding: .utf8)) ?? ""
            let hdr = Self.header(cur).map { "@id:\($0)\n" } ?? ""
            log.append("EXTERNAL write \(rel(f.url))")
            try? (hdr + "ext\(st.b) external body").write(to: f.url, atomically: true, encoding: .utf8)
            if fastWatcher { s.reloadTree() }
            return true
        case .extDelete:
            let fs = mdFiles(); guard !fs.isEmpty else { return false }
            let f = fs[st.a % fs.count]
            if avoidKnown && soleTabOfBackgroundPane(f.url) { return false }; log.append("EXTERNAL delete \(rel(f.url))")
            try? fm.removeItem(at: f.url)
            if fastWatcher { s.reloadTree() }
            return true
        case .extRename:
            let fs = mdFiles(); guard !fs.isEmpty else { return false }
            let f = fs[st.a % fs.count]
            if avoidKnown && soleTabOfBackgroundPane(f.url) { return false }
            let dest = f.url.deletingLastPathComponent().appendingPathComponent("ext-renamed-\(st.b).md")
            log.append("EXTERNAL rename \(rel(f.url)) → \(dest.lastPathComponent)")
            try? fm.moveItem(at: f.url, to: dest)
            if fastWatcher { s.reloadTree() }
        case .reload:
            log.append("reloadTree (watcher)"); s.reloadTree()
        case .replace:
            log.append("replaceInVault ext→EXT"); _ = s.replaceInVault(find: "ext", with: "EXT", caseSensitive: true)
        case .resolveReload:
            guard s.externalConflict != nil else { return false }
            log.append("resolveConflictReloadingDisk"); s.resolveConflictReloadingDisk(); return true
        case .resolveMine:
            guard s.externalConflict != nil else { return false }
            log.append("resolveConflictKeepingMine"); s.resolveConflictKeepingMine()
        case .restoreMissing:
            guard s.missingOnDisk else { return false }
            log.append("restoreMissingNote"); s.restoreMissingNote()
        case .closeMissing:
            guard s.missingOnDisk else { return false }
            log.append("closeMissingNote"); s.closeMissingNote(); return true
        case .switchVault:
            log.append("openVault(other) + back")
            func pinned() -> Set<String> {
                Set(s.panes.flatMap(\.tabs).filter { $0.isPinned && FileManager.default.fileExists(atPath: $0.file.url.path) }
                    .map { rel($0.file.url) })
            }
            let before = pinned()
            s.openVault(at: other); s.notice = nil
            if s.vaultRoot?.standardizedFileURL == other.standardizedFileURL {
                s.openVault(at: p.root)
                let after = pinned()
                if before != after && failure == nil { failure = "pins not restored: before \(before.sorted()) after \(after.sorted())" }
            }
        case .template:
            // Templater-style create over an existing note (confirmed "Replace").
            let fs = mdFiles(); guard !fs.isEmpty else { return false }
            let f = fs[st.a % fs.count]; log.append("createNote(relativePath: \(rel(f.url))) over existing")
            nextNoteID += 1
            s.createNote(relativePath: rel(f.url), text: "@id:\(nextNoteID)\ntemplate", cursorOffset: nil)
            return true
        }
        return false
    }

    // MARK: invariants
    func check(afterStep i: Int, discard: Bool) {
        guard failure == nil else { return }
        // Judge a quiescent state: an autosave still in flight is provisionally
        // clean with the old text on disk, which is fine mid-save (and on a slow
        // CI runner it's still in flight when this runs).
        let deadline = Date().addingTimeInterval(2)
        while s.hasSavesInFlight && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        if fastWatcher { s.reloadTree(); s.notice = nil }
        let found = foundTokens()
        let lost = liveTokens.subtracting(found)
        if !discard && !lost.isEmpty { failure = "step \(i): typed text lost: \(lost.sorted())"; return }
        liveTokens.formIntersection(found)

        // Cross-contamination: a file holds another note's tokens.
        for (u, t) in allDiskFiles() {
            guard let h = Self.header(t) else { continue }
            for tok in Self.tokens(in: t) where !tok.hasPrefix("⟦\(h).") {
                failure = "step \(i): \(rel(u)) (note \(h)) contains \(tok) typed into another note"; return
            }
        }
        // Structure.
        let ids = s.panes.flatMap(\.tabs).map(\.id)
        if Set(ids).count != ids.count && ProcessInfo.processInfo.environment["PROBE_ALLOW_DUP_IDS"] == nil {
            failure = "step \(i): duplicate tab ids across panes"; return
        }
        if let ap = s.activePane {
            let at = ap.tabs.first { $0.id == ap.activeTabID }
            if at?.file.url != s.selectedFile?.url {
                failure = "step \(i): selectedFile \(s.selectedFile?.name ?? "nil") ≠ active tab \(at?.file.name ?? "nil")"; return
            }
            if at == nil && !ap.tabs.isEmpty { failure = "step \(i): active pane has tabs but no active tab"; return }
        }
        if s.panes.count > 1 && s.panes.contains(where: { $0.tabs.isEmpty }) {
            failure = "step \(i): an empty pane lingers in a split"; return
        }
        // Same note open twice in one pane.
        for (pi, pane) in s.panes.enumerated() {
            let paths = pane.tabs.map { $0.file.url.standardizedFileURL.path.lowercased() }
            if Set(paths).count != paths.count { failure = "step \(i): pane \(pi) has the same note in two tabs"; return }
        }
        // Tabs vs disk (only meaningful right after the watcher has run).
        if fastWatcher {
            for pane in s.panes {
                for t in pane.tabs {
                    let live = pane.id == s.activePaneID && t.id == pane.activeTabID
                    let missing = live ? s.missingOnDisk : t.missingOnDisk
                    let exists = FileManager.default.fileExists(atPath: t.file.url.path)
                    if !exists && !missing { failure = "step \(i): tab \(t.file.name) points at a missing file, not flagged"; return }
                    let dirty = live ? s.isDirty : t.isDirty
                    let conflict = live ? s.externalConflict : t.externalConflict
                    let text = live ? s.activeText : t.text
                    if exists && !dirty && conflict == nil,
                       let disk = try? String(contentsOf: t.file.url, encoding: .utf8), disk != text {
                        failure = "step \(i): clean tab \(t.file.name)\(live ? " (live)" : "") shows \(text.debugDescription) but disk has \(disk.debugDescription)"; return
                    }
                }
            }
        }
    }

    func finalCheck() {
        guard failure == nil else { return }
        let conflicted = s.externalConflict != nil || s.missingOnDisk
            || s.panes.flatMap(\.tabs).contains { $0.externalConflict != nil || $0.missingOnDisk }
        let unsaved = s.saveAllForClose()
        if !conflicted && !unsaved.isEmpty { failure = "final: saveAllForClose returned \(unsaved) with nothing conflicted"; return }
        if unsaved.isEmpty {
            let disk = Set(allDiskFiles().flatMap { Self.tokens(in: $0.1) })
            let lost = liveTokens.subtracting(disk)
            if !lost.isEmpty { failure = "final: saveAllForClose returned [] but not on disk: \(lost.sorted())" }
        }
    }
}

func generateSteps(seed: UInt64, count: Int, skip: Set<String>) -> [RStep] {
    var rng = SplitMix64(state: seed)
    let weights: [(ROp, Int)] = [
        (.open, 10), (.type, 16), (.wait, 8), (.switchTab, 6), (.split, 2), (.focus, 5), (.moveTab, 4),
        (.closeTab, 4), (.pin, 3), (.save, 2), (.renameFile, 3), (.renameFolder, 2), (.moveFile, 3),
        (.delete, 2), (.undo, 3), (.newNote, 2), (.extWrite, 3), (.extDelete, 2), (.extRename, 2),
        (.reload, 3), (.replace, 1), (.resolveReload, 2), (.resolveMine, 2), (.restoreMissing, 2),
        (.closeMissing, 1), (.switchVault, 1), (.template, 1),
    ].filter { !skip.contains($0.0.rawValue) }
    let total = weights.map(\.1).reduce(0, +)
    return (0..<count).map { _ in
        var r = rng.int(total)
        var op = weights[0].0
        for (o, w) in weights { if r < w { op = o; break }; r -= w }
        return RStep(op: op, a: rng.int(1000), b: rng.int(1000), c: rng.int(1000))
    }
}

/// Run a sequence; returns the failure (if any) and the log.
func runSequence(_ steps: [RStep], fastWatcher: Bool, trace: Bool = false) -> (String?, [String]) {
    let m = RandomModel(fastWatcher: fastWatcher)
    defer { m.cleanup() }
    for (i, st) in steps.enumerated() {
        let discard = m.apply(st)
        m.s.notice = nil
        m.check(afterStep: i, discard: discard)
        if trace {
            print("    [\(i)] \(m.log.last ?? "-") discard=\(discard)\n        \(m.p.describe()) saved=\(m.s.savedText.debugDescription) conflict=\(m.s.externalConflict.debugDescription) missing=\(m.s.missingOnDisk)")
            for (u, t) in m.allDiskFiles() { print("        disk \(m.rel(u)) = \(t.debugDescription)") }
            for (pi, pane) in m.s.panes.enumerated() { for t in pane.tabs { print("        snap p\(pi) \(t.file.name) text=\(t.text.debugDescription) saved=\(t.savedText.debugDescription)") } }
        }
        if m.failure != nil { break }
    }
    m.finalCheck()
    return (m.failure, m.log)
}

func shrink(_ steps: [RStep], fastWatcher: Bool, signature: String) -> [RStep] {
    func sig(_ f: String) -> String {
        // Compare failure kinds, not step numbers/tokens.
        let noStep = f.replacingOccurrences(of: #"step \d+: "#, with: "", options: .regularExpression)
        return String(noStep.prefix(while: { $0 != "⟦" && $0 != ":" && $0 != "(" }))
    }
    let want = sig(signature)
    var cur = steps
    var chunk = max(1, cur.count / 2)
    while chunk >= 1 {
        var i = 0
        var progressed = false
        while i < cur.count {
            var cand = cur
            cand.removeSubrange(i..<min(cur.count, i + chunk))
            let (f, _) = runSequence(cand, fastWatcher: fastWatcher)
            if let f, sig(f) == want { cur = cand; progressed = true } else { i += chunk }
        }
        if !progressed { chunk /= 2 }
    }
    return cur
}

func probeRandomChecks() {
    let env = ProcessInfo.processInfo.environment
    let seeds = Int(env["PROBE_SEEDS"] ?? "") ?? 20
    let stepsN = Int(env["PROBE_STEPS"] ?? "") ?? 120
    let seed0 = UInt64(env["PROBE_SEED0"] ?? "") ?? 1
    let fast = (env["PROBE_WATCH"] ?? "fast") == "fast"
    let skip = Set((env["PROBE_SKIP"] ?? "").split(separator: ",").map(String.init))
    var failures = 0
    for seed in seed0..<(seed0 + UInt64(seeds)) {
        let steps = generateSteps(seed: seed, count: stepsN, skip: skip)
        let (f, _) = runSequence(steps, fastWatcher: fast)
        guard let f else { continue }
        failures += 1
        print("seed \(seed): \(f)")
        if env["PROBE_NOSHRINK"] != nil { continue }
        let small = shrink(steps, fastWatcher: fast, signature: f)
        let (f2, log) = runSequence(small, fastWatcher: fast, trace: env["PROBE_TRACE"] != nil)
        print("  shrunk to \(small.count) steps → \(f2 ?? "(no longer fails)")")
        for l in log { print("    \(l)") }
        if env["PROBE_FIRST"] != nil { break }
    }
    expectEqual(failures, 0, "random model runs failing")
}
