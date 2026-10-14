import SwiftUI

@main
struct MultiStreamDemoApp: App {
    @StateObject private var viewModel = DemoViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
