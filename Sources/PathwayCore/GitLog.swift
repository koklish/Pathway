import Foundation

/// Ссылка, указывающая на коммит: ветка, серверная ветка или тег.
public struct CommitRef: Equatable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Ветка, на которой стоит HEAD. Рисуется иначе: это «вы здесь».
        case head
        case branch
        case remote
        case tag
    }

    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// Коммит в истории.
public struct Commit: Equatable, Sendable, Identifiable {
    public var id: String { hash }
    public let hash: String
    /// Родители: один у обычного коммита, два и больше — у слияния, ноль — у
    /// самого первого.
    public let parents: [String]
    public let author: String
    public let date: Date
    public let subject: String
    public let refs: [CommitRef]

    /// Семь символов — та же длина, что показывает сам git и что уже принята
    /// в чипе для отделённой головы.
    public var shortHash: String { String(hash.prefix(7)) }

    /// Слияние: два родителя и больше.
    ///
    /// Признак нужен не только графу: строки «Merge branch …» служебные и
    /// рисуются приглушённо — в ветвистой истории их до трети, и в полную
    /// силу они забивали бы содержательные сообщения.
    public var isMerge: Bool { parents.count > 1 }

    public init(
        hash: String, parents: [String], author: String, date: Date,
        subject: String, refs: [CommitRef]
    ) {
        self.hash = hash
        self.parents = parents
        self.author = author
        self.date = date
        self.subject = subject
        self.refs = refs
    }
}

/// Разбор вывода `git log`.
///
/// Чистая функция: история проверяется без запуска git и без репозитория.
public enum GitLog {

    /// Разделитель полей — управляющий символ \u{1}, как в BranchList.
    static let fieldSeparator: Character = "\u{1}"

    /// Разделитель записей — \u{0}.
    ///
    /// Не перевод строки: сообщение коммита содержит переносы, и разбор по
    /// строкам порвал бы один коммит на несколько. Нулевой байт в текст
    /// сообщения попасть не может — git отвергает его в объектах.
    static let recordSeparator: Character = "\u{0}"

    /// Формат записи. Тема идёт последней намеренно: только она содержит
    /// произвольный текст, и стоя в конце не может сдвинуть остальные поля.
    static let format = "%H\u{1}%P\u{1}%an\u{1}%at\u{1}%D\u{1}%s"

    /// Аргументы запроса истории.
    ///
    /// `--date-order`, а не порядок по умолчанию: он ставит коммиты в порядке
    /// времени, не разрывая ветку на куски, — граф от этого читается сверху
    /// вниз, как лента, а не прыгает между дорожками.
    public static func arguments(limit: Int, skip: Int = 0) -> [String] {
        var arguments = [
            // %x00, а не сам нулевой байт в строке: буквальный \0 git из
            // формата выбрасывает, и записи слиплись бы в одну — сообщение
            // следующего коммита уехало бы в тему предыдущего. Проверено на
            // живом git, фейк этого не ловит.
            "log", "--date-order", "--format=\(format)%x00",
            "--max-count=\(limit)",
        ]
        if skip > 0 { arguments.append("--skip=\(skip)") }
        return arguments
    }

    /// Разбирает вывод. `remotes` — имена удалённых из `git remote`: только по
    /// ним серверная ветка отличается от локальной со слэшем в имени.
    public static func parse(_ output: String, remotes: [String] = ["origin"]) -> [Commit] {
        output
            .split(separator: recordSeparator, omittingEmptySubsequences: true)
            .compactMap { parseRecord($0, remotes: remotes) }
    }

    private static func parseRecord(_ record: Substring, remotes: [String]) -> Commit? {
        // Ведущие переводы строки остаются от разделителя записей: git ставит
        // \n после каждой записи, и он приклеивается к началу следующей.
        let text = record.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return nil }

        // maxSplits: тема идёт последней и может содержать сам разделитель
        // только если его туда записали — но даже тогда она останется целой.
        let parts = text.split(
            separator: fieldSeparator, maxSplits: 5, omittingEmptySubsequences: false
        )
        guard parts.count == 6 else { return nil }

        let hash = String(parts[0])
        guard !hash.isEmpty else { return nil }

        let parents = parts[1]
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let date = TimeInterval(parts[3]).map(Date.init(timeIntervalSince1970:)) ?? Date(timeIntervalSince1970: 0)

        return Commit(
            hash: hash,
            parents: parents,
            author: String(parts[2]),
            date: date,
            subject: String(parts[5]),
            refs: parseRefs(String(parts[4]), remotes: remotes)
        )
    }

    /// Разбирает поле %D: «HEAD -> main, origin/main, tag: v1.3.5».
    static func parseRefs(_ text: String, remotes: [String] = ["origin"]) -> [CommitRef] {
        text.split(separator: ",", omittingEmptySubsequences: true).compactMap { part in
            let name = part.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }

            if name.hasPrefix("tag: ") {
                return CommitRef(name: String(name.dropFirst("tag: ".count)), kind: .tag)
            }
            if name.hasPrefix("HEAD -> ") {
                return CommitRef(name: String(name.dropFirst("HEAD -> ".count)), kind: .head)
            }
            // Голая HEAD без стрелки — отделённая голова: ветки нет, и показать
            // человеку остаётся само слово.
            if name == "HEAD" {
                return CommitRef(name: "HEAD", kind: .head)
            }
            // Серверная ветка узнаётся по имени удалённого, а не по наличию
            // слэша: локальная feature/SDLC/14 содержит его тоже. Сравнение по
            // сегменту целиком, а не по префиксу строки: ветка forkfix/main
            // начинается на «fork», но удалённым не является.
            if let slash = name.firstIndex(of: "/"),
               remotes.contains(String(name[name.startIndex..<slash])) {
                return CommitRef(name: name, kind: .remote)
            }
            return CommitRef(name: name, kind: .branch)
        }
    }
}
