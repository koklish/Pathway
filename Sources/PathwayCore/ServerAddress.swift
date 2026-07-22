import Foundation

/// Разобранный адрес сетевого сервера.
///
/// Пользователи пишут адрес по-разному: «//samba.ip.pro», «smb://samba.ip.pro/share»,
/// просто «nas.local». Разбор приводит всё это к валидному URL с явной схемой.
public struct ServerAddress: Equatable, Hashable, Sendable {
    /// Схема без «://» — smb, ftp, afp, https…
    public let scheme: String
    public let host: String
    /// Путь к ресурсу без ведущего слэша; пустой, если указан только хост.
    public let share: String

    public init(scheme: String, host: String, share: String) {
        self.scheme = scheme
        self.host = host
        self.share = share
    }

    /// Схемы, которые умеет монтировать NetFS.
    public static let knownSchemes = ["smb", "afp", "nfs", "ftp", "http", "https", "cifs"]

    /// Схема по умолчанию: чаще всего подключают SMB.
    public static let defaultScheme = "smb"

    public var url: URL {
        var text = "\(scheme)://\(host)"
        if !share.isEmpty { text += "/\(share)" }
        // Пробелы и кириллица в имени шары — обычное дело, их нужно экранировать.
        let allowed = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "://@"))
        return URL(string: text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text)
            ?? URL(string: "\(scheme)://\(host)")!
    }

    /// Имя для показа в списке: «Общие (nas-office.local)» или просто хост.
    public var displayName: String {
        let lastComponent = share.split(separator: "/").last.map(String.init)
        guard let lastComponent, !lastComponent.isEmpty else { return host }
        return "\(lastComponent) (\(host))"
    }

    /// Разбирает то, что ввёл пользователь. Возвращает nil, если хоста нет.
    ///
    /// Понимает и Windows-нотацию: «\\samba.ip.pro\share» — тот же адрес,
    /// что и «smb://samba.ip.pro/share».
    public static func parse(_ input: String) -> ServerAddress? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Обратные слэши — разделители пути в UNC; дальше разбор общий.
        text = text.replacingOccurrences(of: #"\"#, with: "/")

        var scheme = defaultScheme
        if let range = text.range(of: "://") {
            let parsed = String(text[text.startIndex..<range.lowerBound]).lowercased()
            guard knownSchemes.contains(parsed) else { return nil }
            scheme = parsed
            text = String(text[range.upperBound...])
        } else if text.hasPrefix("//") {
            // Привычная запись «//samba.ip.pro» — та же схема по умолчанию.
            text = String(text.dropFirst(2))
        }

        // Логин в адресе (user@host) отбрасываем: учётные данные вводятся отдельно.
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }

        // Экранирование снимаем покомпонентно: адрес приходит и от пользователя
        // («/Общие»), и от системы — getmntinfo отдаёт f_mntfromname уже
        // экранированным. Без этого share остаётся строкой «%D0%9E%D0%B1…»:
        // она не совпадает с закладкой на тот же ресурс, а url экранирует её
        // повторно, превращая «%» в «%25».
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }
        guard let host = parts.first, !host.isEmpty, !host.contains(" ") else { return nil }

        return ServerAddress(scheme: scheme, host: host, share: parts.dropFirst().joined(separator: "/"))
    }
}
