import SwiftUI
import Combine
import ExtensionSDK
import TemplateKit

/// Daily, weekly, monthly, quarterly and yearly notes, configured by the vault's
/// periodic-notes `data.json` (shared with Obsidian's Periodic Notes). Everything
/// it offers — its commands, its settings pane, and the daily-note service
/// Calendar uses — is registered through the SDK, so switching the plugin off
/// removes all of it.
public struct PeriodicNotesPlugin: Plugin {
    public static let id = "io.hanji.periodicnotes"
    public static let displayName = "Periodic Notes"
    public init() {}

    public func activate(host: PluginHost) {
        // Holds the workspace weakly, so the commands and the service can keep it
        // strongly without a cycle through the host.
        let notes = PeriodicNotes(workspace: host.workspace, activeNotePath: host.editor.activeNotePath)
        for kind in PeriodicKind.allCases {
            host.commands.register(Command(id: "periodic.\(kind.rawValue)", title: Self.title(kind),
                                           isAvailable: { notes.isEnabled(kind) }) {
                notes.open(kind, date: Date())
            })
        }
        host.commands.register(Command(id: "periodic.previous", title: "Go to previous periodic note",
                                       isAvailable: { notes.activeKind != nil }) { notes.go(-1) })
        host.commands.register(Command(id: "periodic.next", title: "Go to next periodic note",
                                       isAvailable: { notes.activeKind != nil }) { notes.go(1) })
        host.services.provideDailyNotes(notes)
        host.ui.addSettingsView(id: "periodic-notes", title: "Periodic Notes") { [weak ws = host.workspace] in
            AnyView(PeriodicSettingsView(vaultRoot: ws?.vaultRoot))
        }
    }

    static func title(_ kind: PeriodicKind) -> String {
        switch kind {
        case .daily: return "Open today's daily note"
        case .weekly: return "Open this week's note"
        case .monthly: return "Open this month's note"
        case .quarterly: return "Open this quarter's note"
        case .yearly: return "Open this year's note"
        }
    }
}

final class PeriodicNotes: DailyNotesService {
    private weak var workspace: WorkspaceActions?
    private var activePath: String?
    private var subscription: AnyCancellable?

    init(workspace: WorkspaceActions, activeNotePath: AnyPublisher<String?, Never>) {
        self.workspace = workspace
        subscription = activeNotePath.sink { [weak self] in self?.activePath = $0 }
    }

    /// Read fresh each time: the settings pane (or Obsidian) may have changed it.
    private var config: PeriodicConfig? { workspace?.vaultRoot.map { PeriodicConfig.load(vaultRoot: $0) } }

    func isEnabled(_ kind: PeriodicKind) -> Bool { config?.settings(for: kind).enabled ?? false }

    /// The period of the open note, if it is a periodic note.
    var activeKind: PeriodicKind? {
        guard let path = activePath else { return nil }
        return config?.kind(ofNotePath: path)
    }

    /// Open the `kind` note for `date`, creating it from its template if needed.
    func open(_ kind: PeriodicKind, date: Date) {
        guard let ws = workspace, let cfg = config else { return }
        let action = cfg.planOpen(kind, date: date,
                                  exists: { ws.noteExists(relativePath: $0) },
                                  readTemplate: { ws.readNote(relativePath: $0) })
        switch action {
        case .open(let path):
            ws.openNote(relativePath: path)
        case .create(let path, let text, let cursor):
            ws.createNote(relativePath: path, text: text, cursorOffset: cursor)
            ws.openNote(relativePath: path)
        }
    }

    /// Jump to the closest existing note of the open note's period.
    func go(_ direction: Int) {
        guard let ws = workspace, let cfg = config, let path = activePath,
              let target = cfg.adjacentNote(from: path, direction: direction,
                                            exists: { ws.noteExists(relativePath: $0) })
        else { return }
        ws.openNote(relativePath: target)
    }

    // DailyNotesService (Calendar)
    func hasDailyNote(on date: Date) -> Bool {
        guard let ws = workspace, let cfg = config else { return false }
        return ws.noteExists(relativePath: cfg.notePath(.daily, date: date))
    }

    func openDailyNote(on date: Date) { open(.daily, date: date) }
}

/// Settings ▸ Periodic Notes: each period's switch, folder, file-name format and
/// template, written back to the vault's periodic-notes `data.json`.
struct PeriodicSettingsView: View {
    let vaultRoot: URL?
    @State private var drafts: [PeriodicKind: Draft] = [:]
    @State private var status: String?

    struct Draft: Equatable {
        var enabled: Bool
        var folder: String
        var format: String
        var template: String
    }

    var body: some View {
        if let vaultRoot {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(PeriodicKind.allCases, id: \.self) { kind in section(kind) }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Save") { save(vaultRoot) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .onAppear { load(vaultRoot) }
        } else {
            Text("Open a vault to configure its periodic notes.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func section(_ kind: PeriodicKind) -> some View {
        let draft = binding(kind)
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Enabled", isOn: draft.enabled)
                LabeledContent("Folder") { TextField("vault root", text: draft.folder) }
                LabeledContent("Format") {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(PeriodicConfig.defaults(kind).format, text: draft.format)
                        Text(preview(kind)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Template") { TextField("none", text: draft.template) }
            }
            .disabled(!draft.wrappedValue.enabled)
        } label: {
            Text(kind.rawValue.capitalized).font(.headline)
        }
    }

    private func binding(_ kind: PeriodicKind) -> Binding<Draft> {
        Binding(get: { drafts[kind] ?? Draft(enabled: true, folder: "", format: "", template: "") },
                set: { drafts[kind] = $0; status = nil })
    }

    /// What the current note's file would be called, e.g. "Daily/2026-06-09.md".
    private func preview(_ kind: PeriodicKind) -> String {
        let d = drafts[kind]
        let format = (d?.format.isEmpty ?? true) ? PeriodicConfig.defaults(kind).format : d!.format
        let name = MomentFormat.format(Date(), format) + ".md"
        let folder = d?.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) ?? ""
        return "Now: " + (folder.isEmpty ? name : folder + "/" + name)
    }

    private func load(_ root: URL) {
        let cfg = PeriodicConfig.load(vaultRoot: root)
        for kind in PeriodicKind.allCases {
            let s = cfg.settings(for: kind)
            drafts[kind] = Draft(enabled: s.enabled, folder: s.folder, format: s.format,
                                 template: s.template.map { $0.hasSuffix(".md") ? String($0.dropLast(3)) : $0 } ?? "")
        }
    }

    private func save(_ root: URL) {
        var cfg = PeriodicConfig.load(vaultRoot: root)
        for (kind, d) in drafts {
            let template = d.template.trimmingCharacters(in: .whitespaces)
            cfg.set(PeriodicSettings(
                folder: d.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
                format: d.format.isEmpty ? PeriodicConfig.defaults(kind).format : d.format,
                template: template.isEmpty ? nil : (template.hasSuffix(".md") ? template : template + ".md"),
                enabled: d.enabled), for: kind)
        }
        do {
            try cfg.save(vaultRoot: root)
            status = "Saved to .obsidian/plugins/periodic-notes/data.json"
        } catch {
            status = "Couldn\u{2019}t save: \(error.localizedDescription)"
        }
    }
}
