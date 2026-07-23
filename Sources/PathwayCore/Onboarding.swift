import Foundation
import Observation

/// Элемент интерфейса, который подсвечивает шаг онбординга.
///
/// UI сопоставляет кейс координатам реального вью. `versionChip` особый: чип
/// версии живёт в отдельном слое тулбара macOS, недостижимом для SwiftUI-overlay,
/// — вырез вокруг него сделать нельзя, поэтому его карточка встаёт в углу.
public enum OnboardingTarget: Equatable, Sendable {
    case none          // центр окна, без выреза (приветствие, готово)
    case addressBar    // адресная строка целиком
    case sidebar       // сайдбар / дерево папок целиком
    case connectServer // кнопка «Подключиться к серверу…»
    case versionChip   // чип версии в тулбаре — карточка в углу, без выреза
}

/// Шаг тура. Порядок и прогресс «N из 6» берутся из `rawValue`.
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, addressBar, sidebar, connectServer, updates, done

    public var title: String {
        switch self {
        case .welcome: "Добро пожаловать в Проводник"
        case .addressBar: "Адресная строка"
        case .sidebar: "Дерево папок и избранное"
        case .connectServer: "Сетевые серверы"
        case .updates: "Обновления"
        case .done: "Готово"
        }
    }

    public var body: String {
        switch self {
        case .welcome:
            "Файловый менеджер для macOS в духе Проводника Windows: редактируемый "
            + "путь, дерево папок и вкладки. Быстро пройдёмся по главному."
        case .addressBar:
            "Каждый сегмент пути кликабелен — мгновенный переход на любой уровень. "
            + "Кликните по строке (или ⌘L), чтобы ввести путь текстом."
        case .sidebar:
            "Слева — «Этот Mac», диски и ваши папки. Часто нужные папки "
            + "перетащите в «Избранное»."
        case .connectServer:
            "Подключайте удалённые диски по SMB, FTP, SFTP и WebDAV (⌘K). "
            + "Серверы появляются в сайдбаре в разделе «Сеть»."
        case .updates:
            "Приложение само проверяет обновления. Точка рядом с номером версии — "
            + "доступна новая версия; нажмите на неё, чтобы установить."
        case .done:
            "Это всё главное. Тур можно повторить кнопкой «?» справа вверху "
            + "в любой момент."
        }
    }

    public var target: OnboardingTarget {
        switch self {
        case .welcome, .done: .none
        case .addressBar: .addressBar
        case .sidebar: .sidebar
        case .connectServer: .connectServer
        case .updates: .versionChip
        }
    }
}

/// Управление обучающим туром: текущий шаг, навигация и флаг «уже показан».
///
/// Логика вынесена в Core и тестируется без UI. Флаг `onboarding.shown` устроен
/// как `favorites.seeded` в FavoritesStore: он переживает перезапуск и
/// обновление (обновление не сбрасывает UserDefaults), поэтому тур сам
/// появляется лишь при первом локальном запуске.
@Observable
@MainActor
public final class OnboardingModel {
    /// nil — тур не идёт.
    public private(set) var currentStep: OnboardingStep?

    private let defaults: UserDefaults
    private let shownKey = "onboarding.shown"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isActive: Bool { currentStep != nil }

    /// Первый локальный запуск: если тур ещё не показывали — запустить и
    /// пометить показанным. Иначе ничего.
    public func startIfFirstLaunch() {
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)
        currentStep = .welcome
    }

    /// Ручной запуск с кнопки «?» — всегда с первого шага, флаг не трогает:
    /// повторный тур не зависит от первого запуска.
    public func start() {
        currentStep = .welcome
    }

    public func next() {
        guard let step = currentStep else { return }
        guard let following = OnboardingStep(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        currentStep = following
    }

    public func back() {
        guard let step = currentStep,
              let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        currentStep = previous
    }

    public func skip() {
        finish()
    }

    private func finish() {
        currentStep = nil
    }
}
