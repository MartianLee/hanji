import Foundation
import AppCore
import VaultKit
import MKSearchKit

/// Shared scaffolding for the exploratory note/tab/file-model probes.
final class ProbeVault {
    let fm = FileManager.default
    let root: URL
    let suite: String
    let s: AppState

    init(_ tag: String, files: [String: String], autosave: TimeInterval = 0.05) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hanji-probe-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "hanji-probe-\(tag)-\(UUID().uuidString)"
        s = AppState(defaults: UserDefaults(suiteName: suite)!, autosaveInterval: autosave)
        for (rel, text) in files { put(rel, text) }
        s.openVault(at: root)
    }

    func cleanup() {
        try? fm.removeItem(at: SearchIndex.indexFileURL(forVault: root))
        try? fm.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }
    func put(_ rel: String, _ text: String) {
        let u = url(rel)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }
    func read(_ rel: String) -> String? { try? String(contentsOf: url(rel), encoding: .utf8) }
    func exists(_ rel: String) -> Bool { fm.fileExists(atPath: url(rel).path) }
    func file(_ name: String) -> MarkdownFile? { s.files.first { $0.name == name } }
    func open(_ name: String) { if let f = file(name) { s.open(f, newTab: true) } else { print("  ! no file \(name)") } }
    func tab(_ name: String, pane: Int? = nil) -> OpenTab? {
        let ps = pane.map { [s.panes[$0]] } ?? s.panes
        return ps.flatMap(\.tabs).first { $0.file.name == name }
    }
    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    func describe() -> String {
        s.panes.enumerated().map { i, p in
            let active = p.id == s.activePaneID ? "*" : ""
            let tabs = p.tabs.map { t in
                (t.id == p.activeTabID ? ">" : "") + t.file.name + (t.isPinned ? "📌" : "")
                    + (t.missingOnDisk ? "(missing)" : "") + (t.externalConflict != nil ? "(conflict)" : "")
            }.joined(separator: ",")
            return "pane\(i)\(active)[\(tabs)]"
        }.joined(separator: " ") + " sel=\(s.selectedFile?.name ?? "nil") text=\(s.activeText.debugDescription)"
    }
}
