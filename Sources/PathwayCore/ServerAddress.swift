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
    /// Учётная запись, под которой подключаются к серверу.
    ///
    /// Часть идентичности, а не деталь подключения: один сервер держат открытым
    /// под двумя логинами сразу, и без этого поля вторая закладка вытесняла бы
    /// первую — вместе с её паролем и точкой монтирования.
    ///
    /// nil, а не пустая строка, когда логина нет: пустая сделала бы
    /// «smb://@nas/share» ключом, отличным от «smb://nas/share», и записи,
    /// сохранённые до появления поля, перестали бы находиться.
    public let user: String?

    public init(scheme: String?, host: String, share: String, user: String? = nil) {
        self.scheme = scheme
        self.host = host
        self.share = share
        self.user = user
    }

    /// Схемы, которые умеет монтировать NetFS.
    public static let knownSchemes = ["smb", "afp", "nfs", "ftp", "http", "https", "cifs"]

    /// Тот же адрес с определённой схемой.
    public func with(scheme: String) -> ServerAddress {
        ServerAddress(scheme: scheme, host: host, share: share, user: user)
    }

    /// Тот же адрес с другой учётной записью.
    public func with(user: String?) -> ServerAddress {
        ServerAddress(scheme: scheme, host: host, share: share, user: user)
    }

    /// nil, пока схема неизвестна: смонтировать такой адрес нельзя.
    public var url: URL? {
        guard let scheme else { return nil }
        // Логин попадает в строку до хоста — «smb://ivan@nas/share». Отсюда его
        // и читает parse при обратном разборе, и ключ двух учётных записей на
        // один ресурс расходится сам собой.
        var text = "\(scheme)://"
        if let user, !user.isEmpty { text += "\(user)@" }
        text += host
        if !share.isEmpty { text += "/\(share)" }
        // Пробелы и кириллица в имени шары — обычное дело, их нужно экранировать.
        let allowed = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "://@"))
        // Запасной вариант тоже несёт логин: без него сбой разбора имени ресурса
        // схлопнул бы ключи двух учётных записей в один.
        let bare = user.map { "\(scheme)://\($0)@\(host)" } ?? "\(scheme)://\(host)"
        return URL(string: text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text)
            ?? URL(string: bare)
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

        // Логин в адресе (user@host) сохраняем: он часть идентичности сервера, а
        // не деталь подключения. Раньше он здесь отбрасывался, и два логина на
        // один ресурс давали один ключ — вторая закладка вытесняла первую.
        //
        // lastIndex, а не first: пароль в адрес не пишут, но собака встречается
        // в самом логине (домен вида «ivan@company.ru»), и делить надо по
        // последней — до неё логин, после неё хост.
        // Искать собаку можно только до первого слэша: в имени ресурса она тоже
        // законна, и поиск по всей строке превратил бы «nas/отчёт@2024» в логин
        // «nas/отчёт» с хостом «2024».
        var user: String?
        let hostPart = text.prefix { $0 != "/" }
        if let at = hostPart.lastIndex(of: "@") {
            let parsed = String(text[text.startIndex..<at])
            // Пустой логин («@nas.local») — это отсутствие логина, а не логин из
            // пустой строки: иначе ключ разошёлся бы с адресом без собаки.
            user = parsed.isEmpty ? nil : (parsed.removingPercentEncoding ?? parsed)
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

        return ServerAddress(
            scheme: scheme,
            host: host,
            share: parts.dropFirst().joined(separator: "/"),
            user: user
        )
    }
}
