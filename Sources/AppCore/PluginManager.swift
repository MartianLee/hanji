import Foundation
import ExtensionSDK

public final class PluginManager: ObservableObject {
    @Published public private(set) var sidebar: [SidebarContribution] = []
    public init() {}

    public func activate(_ plugins: [Plugin], host: PluginHost) {
        for plugin in plugins { plugin.activate(host: host) }
    }

    func addSidebar(_ contribution: SidebarContribution) {
        sidebar.append(contribution)
    }
}
