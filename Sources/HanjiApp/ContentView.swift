import SwiftUI
import AppKit
import AppCore
import EditorEngine
import ExtensionSDK
import VaultKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var pluginManager: PluginManager

    private var selection: Binding<MarkdownFile.ID?> {
        Binding(
            get: { appState.selectedFile?.id },
            set: { id in
                if let file = appState.files.first(where: { $0.id == id }) {
                    appState.open(file)
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(appState.files, selection: selection) { file in
                Text(file.name)
            }
            .navigationTitle(appState.vaultRoot?.lastPathComponent ?? "Hanji")
            .toolbar {
                ToolbarItem {
                    Button(action: openVault) { Image(systemName: "folder") }
                        .help("Open vault folder")
                }
            }
        } content: {
            if appState.selectedFile != nil {
                MarkdownEditorView(text: $appState.activeText, renderers: appState.rendererRegistry, vaultRoot: appState.vaultRoot, cursorOffset: $appState.pendingCursorOffset)
                    .toolbar {
                        ToolbarItem { Button("Save", action: appState.save) }
                    }
            } else {
                Text("Open a vault, then select a note")
                    .foregroundStyle(.secondary)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(pluginManager.sidebar) { contribution in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(contribution.title).font(.headline)
                            contribution.makeView()
                        }
                    }
                    if pluginManager.sidebar.isEmpty {
                        Text("No plugins").foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .frame(minWidth: 220)
        }
    }

    private func openVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.openVault(at: url)
        }
    }
}
