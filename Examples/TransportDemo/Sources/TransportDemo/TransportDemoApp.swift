import AppKit
import SwiftUI

@main
struct TransportDemoApp: App {
    @StateObject private var viewModel = TransportViewModel()

    init() {
        // An unbundled SwiftPM executable doesn't get a Dock icon or key window by default.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Transport Demo") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1100, height: 700)
    }
}
