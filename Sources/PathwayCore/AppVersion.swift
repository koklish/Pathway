import Foundation

/// Версия приложения вида `1.2.3`.
///
/// Сравнивается почисленно по компонентам, а не как строка: строковое сравнение
/// поставило бы «1.10.0» перед «1.9.0», и после версии 1.9 обновления перестали
/// бы приходить вовсе.
public struct AppVersion: Sendable, Comparable, CustomStringConvertible {
    public let components: [Int]

    /// Разбирает `1.2.3` или тег `v1.2.3`. Возвращает nil, если чисел нет вовсе.
    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Тег релиза на GitHub принято писать с «v», а CFBundleShortVersionString — без.
        let digits = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            parsed.append(number)
        }
        components = parsed
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        // Недостающие компоненты — нули: «1.2» и «1.2.0» это одна версия.
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }
}
