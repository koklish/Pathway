import Foundation

/// Состояние репозитория: ветка, расхождение с сервером, наличие правок.
public struct GitStatus: Equatable, Sendable {
    public let branch: String?
    /// Коммитов впереди upstream; nil — upstream нет, сравнивать не с чем.
    public let ahead: Int?
    /// Коммитов позади upstream; nil — upstream нет.
    public let behind: Int?
    /// Сколько файлов затронуто: изменённых, добавленных, удалённых,
    /// конфликтных и неотслеживаемых вместе.
    public let changedFiles: Int

    /// Есть ли незакоммиченные изменения, включая неотслеживаемые файлы.
    ///
    /// Выводится из счётчика, а не хранится отдельно: два поля об одном факте
    /// разошлись бы при первой же правке разбора.
    public var isDirty: Bool { changedFiles > 0 }

    public init(branch: String?, ahead: Int?, behind: Int?, changedFiles: Int) {
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.changedFiles = changedFiles
    }

    /// Разбирает вывод `git status --porcelain=v2 --branch`.
    ///
    /// Один вызов даёт ветку, расхождение и грязность разом — отдельные
    /// `git branch` и `git rev-list` стоили бы трёх процессов вместо одного.
    public static func parse(_ output: String) -> GitStatus {
        var branch: String?
        var oid: String?
        var ahead: Int?
        var behind: Int?
        var changedFiles = 0

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                    .trimmingCharacters(in: .whitespaces)
                // «(detached)» — служебное слово git: человеку нужен коммит,
                // на котором он стоит, и его берём из branch.oid ниже.
                branch = value == "(detached)" ? nil : value
            } else if line.hasPrefix("# branch.oid ") {
                oid = String(line.dropFirst("# branch.oid ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("# branch.ab ") {
                // Формат «+3 -2». Строки нет вовсе, когда upstream не задан, —
                // отсюда опциональность счётчиков, а не нули по умолчанию.
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") { ahead = Int(part.dropFirst()) }
                    if part.hasPrefix("-") { behind = Int(part.dropFirst()) }
                }
            } else if let first = line.first, "12u?".contains(first) {
                // 1/2 — изменённое, u — конфликт, ? — неотслеживаемое.
                // Игнорируемые (!) сюда не попадают: git их не печатает без
                // --ignored, и считать их изменениями было бы неверно.
                //
                // Строка «2» (переименование) несёт оба пути разом, но остаётся
                // одним файлом: считай по путям — переименование давало бы два.
                changedFiles += 1
            }
        }

        if branch == nil, let oid, oid.count >= 7, oid != "(initial)" {
            branch = String(oid.prefix(7))
        }
        return GitStatus(branch: branch, ahead: ahead, behind: behind, changedFiles: changedFiles)
    }
}

/// Репозиторий, внутри которого находится текущая папка.
public struct RepositoryState: Equatable, Sendable {
    public let root: URL
    public let branch: String?
    public let ahead: Int?
    public let behind: Int?
    /// Сколько файлов затронуто; 0 — дерево чистое либо статус ещё не считали.
    public let changedFiles: Int

    public var isDirty: Bool { changedFiles > 0 }

    public init(root: URL, branch: String?, ahead: Int? = nil, behind: Int? = nil, changedFiles: Int = 0) {
        self.root = root
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.changedFiles = changedFiles
    }
}

/// Короткое сообщение о результате git-операции.
///
/// Отдельный тип, а не строка: у неудачи другой вид и другой срок показа, и
/// признак приходится держать рядом с текстом. Identifiable — чтобы два подряд
/// одинаковых результата дали новую анимацию: без смены идентификатора второй
/// «Нового нет» остался бы висеть неотличимо от первого, и человек не понял бы,
/// что операция вообще повторилась.
public struct Toast: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case success, failure }

    public let id = UUID()
    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Итог git-операции — всё, из чего складывается текст тоста.
///
/// Тип, а не три аргумента замыкания: их уже три, и четвёртый превратил бы
/// вызовы в ряд безымянных значений, где before и after различимы лишь порядком.
public struct GitOperationResult: Sendable {
    /// Состояние до операции. У push отсюда берётся число отправленного:
    /// локальные коммиты git знает без сети, и устареть этот счётчик не может.
    public let before: GitStatus?
    /// Состояние после. У fetch отсюда берётся отставание: refs к этому моменту
    /// уже свежие, а прирост за вызов ничего не сказал бы, обнови их кто-то
    /// раньше.
    public let after: GitStatus?
    /// Сколько коммитов легло в рабочее дерево за операцию — по разнице HEAD.
    public let arrived: Int

    public init(before: GitStatus?, after: GitStatus?, arrived: Int) {
        self.before = before
        self.after = after
        self.arrived = arrived
    }
}
