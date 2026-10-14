import AppKit
import SwiftUI

@main
struct MultiStreamDemoApp: App {
    @StateObject private var viewModel = DemoViewModel()

    init() {
        // An unbundled SwiftPM executable doesn't get a Dock icon or key window by default.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("MultiStream Demo") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1200, height: 780)
    }
}
