import SwiftUI
import AppCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var pluginManager: PluginManager

    var body: some View {
        TabView {
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            vaultTab
                .tabItem { Label("Vault", systemImage: "folder") }
            pluginsTab
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 480, height: 380)
    }

    /// Obsidian-style appearance settings.
    private var appearanceTab: some View {
        Form {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Font size").font(.headline)
                    Spacer()
                    Text("\(Int(appState.fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Reset") { appState.fontSize = 15 }
                        .disabled(appState.fontSize == 15)
                }
                Text("Change the default font size of the editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $appState.fontSize, in: 12...24, step: 1)
            }
            .padding(.vertical, 4)
        }
        .padding(20)
    }

    /// Obsidian-style plugin toggles (applied live).
    private var pluginsTab: some View {
        Form {
            ForEach(pluginManager.plugins) { plugin in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plugin.displayName)
                        Text(plugin.id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { pluginManager.isEnabled(plugin.id) },
                        set: { pluginManager.setEnabled(plugin.id, $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(20)
    }

    private var vaultTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vault").font(.headline)
            Text(appState.vaultRoot?.path ?? "No vault open").foregroundStyle(.secondary)

            Divider()
            HStack {
                Text("Recent vaults").font(.headline)
                Spacer()
                Button("Clear", role: .destructive) { appState.clearRecents() }
                    .disabled(appState.recentVaults.isEmpty)
            }
            if appState.recentVaults.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                ForEach(appState.recentVaults, id: \.self) { url in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent)
                            Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Open") { appState.openVault(at: url) }
                            .disabled(!FileManager.default.fileExists(atPath: url.path))
                        Button("Remove") { appState.removeRecent(url) }
                    }
                }
            }
            Spacer()
        }
        .padding(20)
    }
}
