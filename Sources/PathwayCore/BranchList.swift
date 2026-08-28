import Foundation

/// Ветка репозитория в списке выбора.
public struct Branch: Equatable, Sendable, Identifiable {
    public var id: String { name }
    /// Имя без префикса удалённого: и `main`, и серверная `origin/main`
    /// зовутся здесь `main` — различает их `isRemote`.
    public let name: String
    /// Лежит только на сервере: переключение создаст локальную копию.
    public let isRemote: Bool
    public let isCurrent: Bool
    /// Дата последнего коммита; nil — git её не отдал.
    public let date: Date?

    public init(name: String, isRemote: Bool = false, isCurrent: Bool = false, date: Date? = nil) {
        self.name = name
        self.isRemote = isRemote
        self.isCurrent = isCurrent
        self.date = date
    }
}

/// Разбор вывода `git for-each-ref`.
///
/// Чистая функция: список веток проверяется без запуска git и без сети.
public enum BranchList {

    /// Разделитель полей — управляющий символ \u{1}.
    ///
    /// Не вертикальная черта и не таб: `git branch 'странная|ветка'` создаётся
    /// без возражений, и такая ветка порвала бы строку — имя разобралось бы
    /// как «странная», а дата как «ветка». Управляющие символы `git
    /// check-ref-format` отвергает, поэтому в имени их не бывает. Проверено.
    static let separator: Character = "\u{1}"

    /// Полный refname, а не сокращённый: только он различает локальную
    /// feature/SDLC/35 и серверную origin/SDLC/35 — обе содержат слэш, и по
    /// нему одну от другой не отличить. Сокращённое имя строится отсюда сами.
    static let format = "%(refname)\u{1}%(committerdate:unix)\u{1}%(symref)"

    /// Аргументы запроса.
    ///
    /// `refs/heads` и `refs/remotes` одним вызовом: два процесса ради
    /// разделения, которое видно по префиксу, — лишняя цена. Сортировка
    /// отдана git: `-committerdate` ставит первой ту ветку, где работали
    /// вчера, а это и есть порядок, нужный человеку.
    static let arguments = [
        "for-each-ref", "--format=\(format)", "--sort=-committerdate",
        "refs/heads", "refs/remotes",
    ]

    public static func parse(_ output: String, current: String?) -> [Branch] {
        var locals: Set<String> = []
        var result: [Branch] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: separator, maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }

            let ref = parts[0]

            // Непустой symref — это origin/HEAD, указатель на ветку по
            // умолчанию, а не ветка: переключение на него дало бы отделённую
            // голову. Отсев именно по symref, а не по имени: в выводе
            // for-each-ref запись сокращается до «origin», без /HEAD, и
            // проверка по строке её не поймала бы.
            guard parts[2].isEmpty else { continue }

            let date = TimeInterval(parts[1]).map(Date.init(timeIntervalSince1970:))

            if ref.hasPrefix("refs/heads/") {
                let name = String(ref.dropFirst("refs/heads/".count))
                guard !name.isEmpty else { continue }
                locals.insert(name)
                result.append(Branch(name: name, isCurrent: name == current, date: date))
            } else if ref.hasPrefix("refs/remotes/") {
                // refs/remotes/origin/feature/X → feature/X: отрезается только
                // имя удалённого, первый сегмент после префикса. Имя ветки
                // само содержит слэши, и резать по последнему нельзя.
                let rest = ref.dropFirst("refs/remotes/".count)
                guard let slash = rest.firstIndex(of: "/") else { continue }
                let name = String(rest[rest.index(after: slash)...])
                guard !name.isEmpty else { continue }
                result.append(Branch(name: name, isRemote: true, date: date))
            }
        }

        // Серверная с локальным двойником не нужна: main и origin/main стояли
        // бы двумя строками, и выбор между ними был бы выбором без разницы —
        // обе ведут на ту же локальную ветку.
        return result.filter { !$0.isRemote || !locals.contains($0.name) }
    }
}
