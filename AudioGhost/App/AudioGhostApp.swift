import SwiftUI

@main
struct AudioGhostApp: App {
    @State private var app = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(app)
        }
    }
}
