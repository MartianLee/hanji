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
        if let obj = readJSONObject(periodic) {
            // Periodic Notes v1.x nests the kinds under a top-level "settings" object; v0.x is flat.
            return parse((obj["settings"] as? [String: Any]) ?? obj)
        }
        // Fallback: core daily-notes.json (daily only).
        let daily = vaultRoot.appendingPathComponent(".obsidian/daily-notes.json")
        if let obj = readJSONObject(daily), let s = settings(from: obj) {
            return PeriodicConfig([.daily: s])
        }
        return PeriodicConfig([:])
    }

    private static func parse(_ obj: [String: Any]) -> PeriodicConfig {
        var map: [PeriodicKind: PeriodicSettings] = [:]
        for kind in PeriodicKind.allCases {
            if let sub = obj[kind.rawValue] as? [String: Any], let s = settings(from: sub) { map[kind] = s }
        }
        return PeriodicConfig(map)
    }

    private static func settings(from obj: [String: Any]) -> PeriodicSettings? {
        // Trim surrounding slashes/spaces so a user-edited "Daily/" doesn't yield "Daily//note.md".
        let folder = ((obj["folder"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
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

public enum OpenAction: Equatable {
    case open(path: String)
    case create(path: String, text: String, cursor: Int?)
}

extension PeriodicConfig {
    /// Decide whether to open an existing periodic note or create one from its template.
    public func planOpen(_ kind: PeriodicKind, date: Date,
                         exists: (String) -> Bool,
                         readTemplate: (String) -> String?,
                         now: Date? = nil,
                         timeZone: TimeZone = .current) -> OpenAction {
        let path = notePath(kind, date: date, timeZone: timeZone)
        if exists(path) { return .open(path: path) }
        let base = (path as NSString).lastPathComponent
        let title = (base as NSString).deletingPathExtension
        let templateText = templatePath(kind).flatMap { readTemplate($0) } ?? ""
        // Default the template clock to the note's own date so the filename and the
        // rendered tp.date.now() can't drift apart for a non-today note.
        let effectiveNow = now ?? date
        let rendered = TemplateEngine.render(templateText,
            TemplateContext(now: effectiveNow, title: title, creationDate: effectiveNow, timeZone: timeZone))
        return .create(path: path, text: rendered.text, cursor: rendered.cursorOffset)
    }
}
