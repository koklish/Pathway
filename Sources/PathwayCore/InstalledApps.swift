import AppKit
import Foundation

/// Приложения, установленные на машине: от них зависит состав подменю «Создать».
///
/// Опрос Launch Services делается один раз, в инициализаторе. Меню строится в
/// menuNeedsUpdate на каждый правый клик, и шесть обращений к системе оттуда —
/// работа на горячем пути.
///
/// Плата за это названа явно: Office, установленный при запущенном приложении,
/// появится в меню только после перезапуска. Отслеживать установку на лету через
/// NSWorkspace.didLaunchApplicationNotification не стали — сложность ради
/// события, которого почти не бывает.
public struct InstalledApps: AppLookup {
    private let found: Set<String>

    /// `probe` подменяется в тестах: настоящий NSWorkspace отвечал бы про
    /// приложения конкретной машины, и проверка зависела бы от того, где её
    /// запустили.
    public init(probe: (String) -> Bool = InstalledApps.systemProbe) {
        let needed = Set(DocumentTemplates.all.compactMap(\.requiredApp))
        found = needed.filter(probe)
    }

    public func isInstalled(bundleID: String) -> Bool {
        found.contains(bundleID)
    }

    public static func systemProbe(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
