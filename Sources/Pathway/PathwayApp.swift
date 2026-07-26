import AppKit
import PathwayCore
import SwiftUI
import UserNotifications

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
        // Онбординг запускается при первом запуске из делегата, а не из
        // MainWindow.onAppear: последний срабатывает повторно при открытии
        // окна из меню «Окно» после ⌘W, а первый запуск — событие процесса.
        appDelegate.onboarding = appState.onboarding
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
final class PathwayAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Проставляется биндингом из PathwayApp до того, как AppKit позовёт
    /// applicationDidFinishLaunching — сервис нужен уже на первом тике.
    var updates: UpdateService?
    /// Тот же экземпляр тура, что и в AppState окна.
    var onboarding: OnboardingModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Бандл предыдущей версии больше не нужен: раз мы выполняемся,
        // обновление удалось.
        BundleUpdateInstaller.cleanUpAfterUpdate()

        // Делегат Центра — до первой проверки: уведомление о найденной версии
        // покажется прямо в ней, и не установи мы делегата заранее, клик по
        // баннеру не дошёл бы ни до кого. Центр берётся только при запуске из
        // бандла: при `swift run` current() бросает исключение.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }

        Task { @MainActor in
            // Порядок существен: сначала разрешение, потом проверка. Иначе на
            // первом запуске проверка успела бы найти версию и показать баннер
            // раньше, чем разрешение вообще запрошено, — и первое уведомление
            // потерялось бы молча.
            await updates?.requestNotificationAuthorization()
            await updates?.checkOnLaunch()
        }
        // Первый локальный запуск — показать обучающий тур. Флаг в UserDefaults
        // переживает обновление, так что повторно тур сам не появится.
        MainActor.assumeIsolated { onboarding?.startIfFirstLaunch() }
    }

    // MARK: - Уведомления

    /// Показывать баннер, даже когда приложение активно.
    ///
    /// Без этого метода macOS глотает уведомления собственного активного
    /// приложения — и весь смысл пропадал бы именно в самом частом случае:
    /// приложение только что запустилось, проверка нашла версию, и окно
    /// на переднем плане.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Клик по баннеру: вывести окно вперёд и попросить раскрыть поповер версии.
    ///
    /// `activate()` обязателен — приложение могло быть свёрнуто или закрыто по
    /// ⌘W, и поповер раскрылся бы в невидимом окне.
    ///
    /// Вариант с `completionHandler`, а не `async`, — единственный, который
    /// проходит проверки Swift 6. У `async`-версии `MainActor.run` захватывает
    /// неизолированный `self` в main-actor-замыкание (гонка), `@MainActor` на
    /// методе не удовлетворяет требованию протокола (`UNNotificationResponse`
    /// не `Sendable`), а `assumeIsolated` из асинхронного контекста недоступен
    /// вовсе. Синхронный метод свободен от всех трёх: AppKit зовёт его на
    /// главном потоке, и `assumeIsolated` здесь утверждает правду.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Сервис берётся в локальную переменную до замыкания: иначе замыкание
        // захватывает `self` целиком, а он у делегата неизолирован — Swift 6
        // видит в этом гонку («task-isolated self is captured by a main
        // actor-isolated closure»). Сама ссылка на сервис в захвате безопасна.
        let updates = updates
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
            updates?.requestPopover()
        }
        completionHandler()
    }
}
