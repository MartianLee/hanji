import Foundation

public enum PeriodicKind: String, CaseIterable {
    case daily, weekly, monthly, quarterly, yearly

    /// `date` moved by `n` whole periods (negative = back).
    public func adding(_ n: Int, to date: Date, timeZone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        switch self {
        case .daily:     return cal.date(byAdding: .day, value: n, to: date)!
        case .weekly:    return cal.date(byAdding: .day, value: 7 * n, to: date)!
        case .monthly:   return cal.date(byAdding: .month, value: n, to: date)!
        case .quarterly: return cal.date(byAdding: .month, value: 3 * n, to: date)!
        case .yearly:    return cal.date(byAdding: .year, value: n, to: date)!
        }
    }

    /// How far previous/next looks for an existing note: about ten years.
    var searchLimit: Int {
        switch self {
        case .daily: return 3660
        case .weekly: return 530
        case .monthly: return 120
        case .quarterly: return 40
        case .yearly: return 10
        }
    }
}

public struct PeriodicSettings: Equatable {
    public let folder: String
    public let format: String
    public let template: String?    // vault-relative path ending in .md, or nil
    /// Periodic Notes' per-period switch. A period the config doesn't mention is on.
    public let enabled: Bool
    public init(folder: String, format: String, template: String?, enabled: Bool = true) {
        self.folder = folder; self.format = format; self.template = template; self.enabled = enabled
    }
}

public struct PeriodicConfig {
    private var map: [PeriodicKind: PeriodicSettings]
    public init(_ map: [PeriodicKind: PeriodicSettings]) { self.map = map }

    public func settings(for kind: PeriodicKind) -> PeriodicSettings { map[kind] ?? PeriodicConfig.defaults(kind) }

    /// Change one period's settings (write them out with `save(vaultRoot:)`).
    public mutating func set(_ settings: PeriodicSettings, for kind: PeriodicKind) { map[kind] = settings }

    /// Periodic Notes' own defaults.
    public static func defaults(_ kind: PeriodicKind) -> PeriodicSettings {
        switch kind {
        case .daily:     return PeriodicSettings(folder: "", format: "YYYY-MM-DD", template: nil)
        case .weekly:    return PeriodicSettings(folder: "", format: "gggg-[W]ww", template: nil)
        case .monthly:   return PeriodicSettings(folder: "", format: "YYYY-MM", template: nil)
        case .quarterly: return PeriodicSettings(folder: "", format: "YYYY-[Q]Q", template: nil)
        case .yearly:    return PeriodicSettings(folder: "", format: "YYYY", template: nil)
        }
    }

    public func notePath(_ kind: PeriodicKind, date: Date, timeZone: TimeZone = .current) -> String {
        let s = settings(for: kind)
        let name = MomentFormat.format(date, s.format, timeZone: timeZone) + ".md"
        return s.folder.isEmpty ? name : s.folder + "/" + name
    }

    public func templatePath(_ kind: PeriodicKind) -> String? { settings(for: kind).template }

    // MARK: - Recognising a periodic note

    /// The date a note at `path` stands for as a `kind` note: it must sit in that
    /// period's folder and its name must be that period's format.
    public func date(ofNotePath path: String, kind: PeriodicKind, timeZone: TimeZone = .current) -> Date? {
        guard path.lowercased().hasSuffix(".md") else { return nil }
        let s = settings(for: kind)
        var name = String(path.dropLast(3))
        if !s.folder.isEmpty {
            guard name.hasPrefix(s.folder + "/") else { return nil }
            name = String(name.dropFirst(s.folder.count + 1))
        }
        return MomentFormat.parse(name, s.format, timeZone: timeZone)
    }

    /// Which enabled period `path` is a note of, trying daily first.
    public func kind(ofNotePath path: String, timeZone: TimeZone = .current) -> PeriodicKind? {
        PeriodicKind.allCases.first {
            settings(for: $0).enabled && date(ofNotePath: path, kind: $0, timeZone: timeZone) != nil
        }
    }

    /// The closest existing note of the same period before (`direction` -1) or
    /// after (+1) the periodic note at `path` — Periodic Notes' "jump backwards /
    /// forwards". Skips periods without a note, looking about ten years out.
    public func adjacentNote(from path: String, direction: Int, exists: (String) -> Bool,
                             timeZone: TimeZone = .current) -> String? {
        guard let kind = kind(ofNotePath: path, timeZone: timeZone),
              let date = date(ofNotePath: path, kind: kind, timeZone: timeZone) else { return nil }
        let step = direction < 0 ? -1 : 1
        for n in 1...kind.searchLimit {
            let candidate = notePath(kind, date: kind.adding(step * n, to: date, timeZone: timeZone), timeZone: timeZone)
            if exists(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Loading

    static func dataURL(_ vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(".obsidian/plugins/periodic-notes/data.json")
    }

    public static func load(vaultRoot: URL) -> PeriodicConfig {
        if let obj = readJSONObject(dataURL(vaultRoot)) {
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
            if let sub = obj[kind.rawValue] as? [String: Any], let s = settings(from: sub, kind: kind) { map[kind] = s }
        }
        return PeriodicConfig(map)
    }

    private static func settings(from obj: [String: Any], kind: PeriodicKind? = nil) -> PeriodicSettings? {
        // Trim surrounding slashes/spaces so a user-edited "Daily/" doesn't yield "Daily//note.md".
        let folder = ((obj["folder"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let enabled = (obj["enabled"] as? Bool) ?? true
        var format = (obj["format"] as? String) ?? ""
        if format.isEmpty {
            // Periodic Notes writes an empty format to mean "the default"; keep an
            // explicit off switch even then.
            guard let kind, obj["enabled"] != nil else { return nil }
            format = defaults(kind).format
        }
        var template: String? = nil
        if let t = obj["template"] as? String, !t.isEmpty {
            template = t.lowercased().hasSuffix(".md") ? t : t + ".md"
        }
        return PeriodicSettings(folder: folder, format: format, template: template, enabled: enabled)
    }

    // MARK: - Saving

    /// Write these settings to the vault's periodic-notes `data.json`, the file
    /// Obsidian's Periodic Notes also reads. Only the keys Hanji manages
    /// (enabled/folder/format/template) change; anything else in the file is kept,
    /// and so is its shape (v1.x nests the periods under "settings").
    public func save(vaultRoot: URL) throws {
        let url = Self.dataURL(vaultRoot)
        var root = Self.readJSONObject(url) ?? [:]
        let nested = root["settings"] is [String: Any]
        var container = nested ? (root["settings"] as! [String: Any]) : root
        for (kind, s) in map {
            var entry = (container[kind.rawValue] as? [String: Any]) ?? [:]
            entry["enabled"] = s.enabled
            entry["folder"] = s.folder
            entry["format"] = s.format
            // Obsidian stores the template path without its extension.
            entry["template"] = s.template.map { $0.lowercased().hasSuffix(".md") ? String($0.dropLast(3)) : $0 } ?? ""
            container[kind.rawValue] = entry
        }
        if nested { root["settings"] = container } else { root = container }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
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
