import SwiftUI
import AppKit
import AppCore

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var pluginManager: PluginManager
    @State private var escape = SettingsEscape.Target()

    var body: some View {
        TabView {
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            vaultTab
                .tabItem { Label("Vault", systemImage: "folder") }
            pluginsTab
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
            // Each enabled plugin's own settings; a pane leaves with its plugin.
            ForEach(pluginManager.settingsPanes) { pane in
                pane.makeView()
                    .tabItem { Label(pane.title, systemImage: "gearshape") }
            }
        }
        .frame(width: 480, height: 380)
        // Esc closes Settings. With a text field focused, the field sees Esc first
        // (a completion list closes on the first press) and this runs only if it
        // passes; with nothing focused, SwiftUI never reports Esc, so a window-
        // scoped key monitor does it.
        .onExitCommand { SettingsEscape.close(escape.window) }
        .background(SettingsEscape(target: escape))
    }

    /// Obsidian-style appearance settings.
    private var appearanceTab: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
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
            Divider().padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("Theme").font(.headline)
                Picker("Theme", selection: $appState.theme) {
                    Text("System").tag(AppearanceTheme.system)
                    Text("Light").tag(AppearanceTheme.light)
                    Text("Dark").tag(AppearanceTheme.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 4)
            Divider().padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Line height").font(.headline)
                    Spacer()
                    Text(String(format: "%.2f", appState.lineHeight))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Reset") { appState.lineHeight = AppState.defaultLineHeight }
                        .disabled(appState.lineHeight == AppState.defaultLineHeight)
                }
                Text("Space between the lines of the editor\u{2019}s body text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $appState.lineHeight, in: AppState.lineHeightRange, step: 0.05)
            }
            .padding(.vertical, 4)
            Divider().padding(.vertical, 8)
            Toggle(isOn: $appState.readableLineLength) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Readable line length").font(.headline)
                    Text("Keep the text in a centred column instead of spanning the window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(20)
        }
    }

    /// Obsidian-style plugin toggles (applied live).
    private var pluginsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                .padding(.vertical, 4)
                Divider()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
                // Up to 8 recents — scroll instead of overflowing the fixed window.
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
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
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

/// Closes the Settings window on Esc (see SettingsView). Never mid-composition:
/// with an input method (e.g. Korean) Esc belongs to the text being composed.
struct SettingsEscape: NSViewRepresentable {
    /// The window this view sits in, for `onExitCommand` (which gets no window of its own).
    final class Target { weak var window: NSWindow? }
    let target: Target

    static func close(_ window: NSWindow?) {
        guard let window else { return }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return }
        window.performClose(nil)
    }

    func makeNSView(context: Context) -> NSView { MonitorView(target: target) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class MonitorView: NSView {
        private let target: Target
        private var monitor: Any?

        init(target: Target) {
            self.target = target
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            target.window = window
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Only this window, only Esc, and only when no text field is
                // focused — a focused field goes through onExitCommand instead.
                guard event.keyCode == 53, let window = self?.window, event.window === window,
                      !(window.firstResponder is NSTextView) else { return event }
                SettingsEscape.close(window)
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
