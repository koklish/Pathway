import Foundation
import UserNotifications

/// Кто показывает системное уведомление о вышедшей версии.
///
/// Протокол, а не прямое обращение к `UNUserNotificationCenter`, — тот же приём,
/// что у `Mounting`, `CredentialStoring`, `TerminalRunning` и `AppTerminating`.
/// Без него тесты сервиса лезли бы в настоящий Центр уведомлений, а он в
/// тестовом процессе недоступен вовсе: приложение там выполняется не из бандла.
///
/// Ни один метод не бросает — намеренно. Показ баннера не влияет на то,
/// доступно ли обновление: синяя точка на чипе версии появляется независимо от
/// разрешений и сбоев Центра. Сигнатура без `throws` делает эту мысль
/// проверяемой компилятором — обрабатывать наверху просто нечего.
public protocol UpdateNotifying: Sendable {
    /// Разовый запрос разрешения. Отказ ошибкой не считается.
    func requestAuthorization() async
    /// Показать баннер про доступную версию.
    func notify(about release: ReleaseInfo) async
}

/// Показывает уведомления через `UNUserNotificationCenter`.
public struct SystemUpdateNotifier: UpdateNotifying {
    /// Текущая версия — нужна, чтобы отобрать из накопительного тела релиза
    /// только заметки новее установленной: первая строка всей истории проекта
    /// в баннере рассказывала бы о выпуске трёхлетней давности.
    private let currentVersion: AppVersion

    public init(currentVersion: AppVersion) {
        self.currentVersion = currentVersion
    }

    public func requestAuthorization() async {
        guard let center = Self.center else { return }
        // Отказ приходит сюда же, но как `false`, а не как ошибка, и делать с
        // ним нечего: своего экрана «включите уведомления» у приложения нет,
        // а системные настройки человек откроет и без нашей подсказки.
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public func notify(about release: ReleaseInfo) async {
        guard let center = Self.center else { return }

        let content = UNMutableNotificationContent()
        content.title = "Доступна версия \(release.version.description)"
        content.body = Self.body(for: release, after: currentVersion)
        // Стандартный звук, а не свой файл: он подчиняется системным настройкам
        // и режиму «Не беспокоить», а собственный выбивался бы из звучания
        // остальных уведомлений.
        content.sound = .default
        // .active, а не .timeSensitive: обновление файлового менеджера не повод
        // пробиваться сквозь «Не беспокоить».
        content.interruptionLevel = .active

        // Идентификатор один на версию. Уведомление показывается при каждом
        // запуске, пока человек не обновился, и без общего идентификатора
        // десять запусков оставили бы в Центре уведомлений десять одинаковых
        // строк — это мусор, а не напоминание. С ним новый баннер заменяет
        // прежний: видно его столько же раз, а в списке остаётся одна запись.
        let request = UNNotificationRequest(
            identifier: "update-\(release.version.description)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    /// Первая строка заметок к выпуску — короткая подсказка, ради чего стоит
    /// обновиться. Берётся из тех же разобранных секций, что показывает поповер,
    /// и только новее установленной версии: тело релиза накопительное.
    ///
    /// Не private: отбор строки — единственная логика в этом типе, которую можно
    /// проверить без настоящего Центра уведомлений, и проверять её стоит.
    static func body(for release: ReleaseInfo, after current: AppVersion) -> String {
        let fallback = "Нажмите, чтобы посмотреть, что изменилось."
        let sections = ReleaseNotes.sections(release.notes, after: current)
        // Плоский разбор как запасной: тело могли отредактировать руками, и
        // тогда секций новее установленной не окажется вовсе, хотя пункты есть.
        let items = sections.first?.items ?? ReleaseNotes.parse(release.notes)
        return items.first ?? fallback
    }

    /// Центр уведомлений, либо nil, если приложение запущено не из бандла.
    ///
    /// При `swift run` бандла нет, и `UNUserNotificationCenter.current()`
    /// не возвращает nil, а бросает исключение — без этой проверки отладочный
    /// запуск падал бы на старте, ещё до появления окна.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
}
