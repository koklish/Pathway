import AppKit

/// Иконки для пунктов контекстных меню.
///
/// Символы берутся из SF Symbols и красятся палитрой: акцентный цвет отделяет
/// разрушающие действия (корзина) от обычных и делает список сканируемым.
/// Размер задаётся в пунктах, а не в пикселях, поэтому иконка следует за
/// системным размером текста меню.
@MainActor
enum MenuIcon {
    /// Символ в цвете. Цвет применяется как палитра SF Symbols, поэтому
    /// многослойные символы (`folder.badge.plus`) остаются читаемыми.
    static func symbol(_ name: String, _ color: NSColor = .secondaryLabelColor) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return image.withSymbolConfiguration(configuration)
    }

    /// Иконка установленного Claude.
    ///
    /// Берём её у самого приложения, а не тащим логотип в ресурсы: так она
    /// всегда актуальна и не дублирует чужой товарный знак в репозитории.
    /// Если приложение не установлено — нейтральный системный символ.
    static var claude: NSImage? {
        if let cached = claudeCache { return cached }
        let icon = claudeAppIcon() ?? symbol("sparkles", .systemOrange)
        icon?.size = NSSize(width: 16, height: 16)
        claudeCache = icon
        return icon
    }

    private static var claudeCache: NSImage?

    private static func claudeAppIcon() -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static let claudeBundleID = "com.anthropic.claudefordesktop"
}
