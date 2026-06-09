import Foundation
import ExtensionSDK
import TemplateKit

public struct PeriodicNotesPlugin: Plugin {
    public static let id = "io.hanji.periodicnotes"
    public init() {}

    public func activate(host: PluginHost) {
        register(host, kind: .daily,   title: "Open today's daily note")
        register(host, kind: .weekly,  title: "Open this week's note")
        register(host, kind: .monthly, title: "Open this month's note")
    }

    private func register(_ host: PluginHost, kind: PeriodicKind, title: String) {
        host.commands.register(Command(id: "periodic.\(kind.rawValue)", title: title) { [weak ws = host.workspace] in
            guard let ws, let root = ws.vaultRoot else { return }
            let now = Date()
            let cfg = PeriodicConfig.load(vaultRoot: root)
            let action = cfg.planOpen(kind, date: now,
                                      exists: { ws.noteExists(relativePath: $0) },
                                      readTemplate: { ws.readNote(relativePath: $0) },
                                      now: now)
            switch action {
            case .open(let path):
                ws.openNote(relativePath: path)
            case .create(let path, let text, let cursor):
                ws.createNote(relativePath: path, text: text, cursorOffset: cursor)
                ws.openNote(relativePath: path)
            }
        })
    }
}
