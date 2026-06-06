import SwiftUI
import AppKit

@main
struct HanjiApp: App {
    var body: some Scene {
        WindowGroup {
            Text("hanji skeleton")
                .frame(width: 360, height: 200)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
    }
}
