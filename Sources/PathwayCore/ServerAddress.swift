import Foundation

/// Разобранный адрес сетевого сервера.
///
/// Пользователи пишут адрес по-разному: «//samba.ip.pro», «smb://samba.ip.pro/share»,
/// просто «nas.local». Разбор приводит всё это к валидному URL с явной схемой.
public struct ServerAddress: Equatable, Hashable, Sendable {
    /// Схема без «://» — smb, ftp, afp, https…
    ///
    /// nil, когда пользователь ввёл голый хост или IP: протокол тогда ещё не
    /// известен и определяется пробой портов. Подставлять smb нельзя —
    /// панель хостинга даёт адрес вида «31.31.196.75», и догадка выдала бы
    /// себя за факт.
    public let scheme: String?
    public let host: String
    /// Путь к ресурсу без ведущего слэша; пустой, если указан только хост.
    public let share: String

    public init(scheme: String?, host: String, share: String) {
        self.scheme = scheme
        self.host = host
        self.share = share
    }

    /// Схемы, которые умеет монтировать NetFS.
    public static let knownSchemes = ["smb", "afp", "nfs", "ftp", "http", "https", "cifs"]

    /// Тот же адрес с определённой схемой.
    public func with(scheme: String) -> ServerAddress {
        ServerAddress(scheme: scheme, host: host, share: share)
    }

    /// nil, пока схема неизвестна: смонтировать такой адрес нельзя.
    public var url: URL? {
        guard let scheme else { return nil }
        var text = "\(scheme)://\(host)"
        if !share.isEmpty { text += "/\(share)" }
        // Пробелы и кириллица в имени шары — обычное дело, их нужно экранировать.
        let allowed = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "://@"))
        return URL(string: text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text)
            ?? URL(string: "\(scheme)://\(host)")
    }

    /// Строка-идентификатор: ключ закладок, множества «подключается», записей
    /// Связки ключей.
    ///
    /// Формат совпадает с url.absoluteString, включая экранирование: закладки
    /// уже сохранены у пользователя в этом виде, и смена формата осиротила бы
    /// их. Для адреса без схемы остаётся хост — такой адрес до монтирования
    /// всё равно не доживает, но ключ нужен, чтобы показать спиннер.
    public var key: String {
        url?.absoluteString ?? host
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

        // Проверяем до замены слэшей: дальше «\\host» и «//host» неразличимы,
        // а знать, что запись была UNC, нужно ради схемы.
        let isUNC = text.hasPrefix(#"\\"#)

        // Обратные слэши — разделители пути в UNC; дальше разбор общий.
        text = text.replacingOccurrences(of: #"\"#, with: "/")

        // Схема известна только там, где пользователь назвал её сам.
        var scheme: String?
        if let range = text.range(of: "://") {
            let parsed = String(text[text.startIndex..<range.lowerBound]).lowercased()
            guard knownSchemes.contains(parsed) else { return nil }
            scheme = parsed
            text = String(text[range.upperBound...])
        } else if isUNC || text.hasPrefix("//") {
            // «\\host\share» и «//host» — запись из мира Windows, она
            // означает SMB и пробы портов не требует.
            scheme = "smb"
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
