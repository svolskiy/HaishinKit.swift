import SwiftUI

@main
struct TransportDemoApp: App {
    @StateObject private var viewModel = TransportViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
