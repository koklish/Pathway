import PathwayCore
import SwiftUI

@main
struct PathwayApp: App {
    @State private var appState = AppState()
    /// Сервис живёт в App, а не в окне: до него дотягивается пункт главного меню.
    @State private var updates = UpdateService()
    // Уборка бандла и автопроверка обновлений — задачи всего процесса, а не
    // конкретного окна: сцена `Window` уничтожает вью-иерархию при закрытии
    // по ⌘W и строит её заново при открытии из меню «Окно», так что
    // `.onAppear` в MainWindow срабатывал бы повторно и разгонял бы лишний
    // запрос к GitHub, а при закрытом окне (пункт меню «Проверить
    // обновления…» всё ещё доступен) автопроверка не шла бы вовсе. Делегат
    // получает `applicationDidFinishLaunching` ровно один раз за жизнь
    // процесса — то, что нужно.
    @NSApplicationDelegateAdaptor(PathwayAppDelegate.self) private var appDelegate

    init() {
        // Делегат создаётся адаптором независимо от других @State-свойств —
        // сервис передаём явно в init, а не через биндинг, чтобы он был на
        // месте уже к моменту applicationDidFinishLaunching.
        appDelegate.updates = updates
    }

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

/// Разовые действия при старте процесса — уборка старого бандла и
/// автопроверка обновлений. Живут здесь, а не в MainWindow, потому что
/// делегат не пересоздаётся вместе с окном (см. комментарий у `body`).
final class PathwayAppDelegate: NSObject, NSApplicationDelegate {
    /// Проставляется биндингом из PathwayApp до того, как AppKit позовёт
    /// applicationDidFinishLaunching — сервис нужен уже на первом тике.
    var updates: UpdateService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Бандл предыдущей версии больше не нужен: раз мы выполняемся,
        // обновление удалось.
        BundleUpdateInstaller.cleanUpAfterUpdate()
        Task { @MainActor in await updates?.checkAutomatically() }
    }
}
