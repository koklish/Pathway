import PathwayCore
import SwiftUI

@main
struct PathwayApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        Window("Pathway", id: "main") {
            MainWindow()
                .environment(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(state: appState)
        }
    }
}
