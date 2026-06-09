import SwiftUI
import AppCore

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    let onOpen: () -> Void
    let onOpenRecent: (URL) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Hanji").font(.largeTitle.bold())
            Text("Open a folder of .md files to get started")
                .foregroundStyle(.secondary)
            Button("Open Vault…", action: onOpen)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            if !appState.recentVaults.isEmpty {
                Divider().frame(maxWidth: 380).padding(.vertical, 8)
                Text("Recent").font(.headline).frame(maxWidth: 380, alignment: .leading)
                ForEach(appState.recentVaults, id: \.self) { url in
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    Button { onOpenRecent(url) } label: {
                        HStack {
                            Image(systemName: "folder")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if !exists { Text("missing").font(.caption).foregroundStyle(.red) }
                        }
                        .frame(maxWidth: 380, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(!exists)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
