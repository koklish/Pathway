import PathwayCore
import SwiftUI

@main
struct PathwayApp: App {
    @State private var appState = AppState()
    /// Сервис живёт в App, а не в окне: до него дотягивается пункт главного меню.
    @State private var updates = UpdateService()

    var body: some Scene {
        // Заголовок «Проводник», а не «Pathway»: внутреннее имя продукта
        // пользователю нигде не показывается.
        Window("Проводник", id: "main") {
            MainWindow(updates: updates)
                .environment(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(state: appState, updates: updates)
        }
    }
}
