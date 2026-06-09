import SwiftUI
import AppCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
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
        .frame(width: 460, height: 340)
    }
}
