import Foundation
import ExtensionSDK

public final class PluginManager: ObservableObject {
    @Published public private(set) var sidebar: [SidebarContribution] = []
    @Published public private(set) var commands: [Command] = []
    @Published public private(set) var statusItems: [StatusItem] = []
    public init() {}

    public func activate(_ plugins: [Plugin], host: PluginHost) {
        for plugin in plugins { plugin.activate(host: host) }
    }

    func addSidebar(_ contribution: SidebarContribution) {
        sidebar.append(contribution)
    }

    func addCommand(_ command: Command) { commands.append(command) }

    func addStatusItem(_ item: StatusItem) { statusItems.append(item) }
}
