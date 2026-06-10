import Foundation
import ExtensionSDK

/// One entry in the plugin roster (Settings ▸ Plugins).
public struct RegisteredPlugin: Identifiable {
    public let id: String
    public let displayName: String
    let instance: any Plugin
}

public final class PluginManager: ObservableObject {
    @Published public private(set) var sidebar: [SidebarContribution] = []
    @Published public private(set) var commands: [Command] = []
    @Published public private(set) var statusItems: [StatusItem] = []
    @Published public private(set) var plugins: [RegisteredPlugin] = []

    /// Which contributions each plugin registered, so a toggle-off removes
    /// exactly those. Tagged automatically while `activate(host:)` runs.
    private struct Ownership { var sidebarIDs: [String] = []; var commandIDs: [String] = []; var statusIDs: [String] = [] }
    private var ownership: [String: Ownership] = [:]
    private var activatingPluginID: String?
    private weak var host: PluginHost?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Register the roster and activate the enabled plugins.
    public func activate(_ list: [any Plugin], host: PluginHost) {
        self.host = host
        for plugin in list {
            let id = type(of: plugin).id
            plugins.append(RegisteredPlugin(id: id, displayName: type(of: plugin).displayName,
                                            instance: plugin))
            if isEnabled(id) { runActivate(plugin, id: id, host: host) }
        }
    }

    // MARK: - Toggles (Obsidian-style, applied live)

    public func isEnabled(_ id: String) -> Bool {
        defaults.object(forKey: Self.key(id)) as? Bool ?? true
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        defaults.set(on, forKey: Self.key(id))
        guard let registered = plugins.first(where: { $0.id == id }) else { return }
        if on {
            guard let host, ownership[id] == nil else { return }   // already active or no host
            runActivate(registered.instance, id: id, host: host)
        } else {
            guard let owned = ownership[id] else { return }        // already inactive
            sidebar.removeAll { owned.sidebarIDs.contains($0.id) }
            commands.removeAll { owned.commandIDs.contains($0.id) }
            statusItems.removeAll { owned.statusIDs.contains($0.id) }
            ownership[id] = nil
            registered.instance.deactivate()
        }
    }

    private func runActivate(_ plugin: any Plugin, id: String, host: PluginHost) {
        activatingPluginID = id
        ownership[id] = Ownership()
        plugin.activate(host: host)
        activatingPluginID = nil
    }

    private static func key(_ id: String) -> String { "io.hanji.plugin.\(id).enabled" }

    // MARK: - Registration (called by Host; tagged to the activating plugin)

    func addSidebar(_ contribution: SidebarContribution) {
        sidebar.append(contribution)
        if let pid = activatingPluginID { ownership[pid]?.sidebarIDs.append(contribution.id) }
    }

    func addCommand(_ command: Command) {
        commands.append(command)
        if let pid = activatingPluginID { ownership[pid]?.commandIDs.append(command.id) }
    }

    func addStatusItem(_ item: StatusItem) {
        statusItems.append(item)
        if let pid = activatingPluginID { ownership[pid]?.statusIDs.append(item.id) }
    }
}
