import Foundation

/// Правила пакетного переименования. Структура-значение: лист редактирует
/// её по полям, а движок строит план из неё без побочных эффектов.
public struct BatchRenameRule: Equatable, Sendable {
    /// Куда ставится порядковый номер.
    public enum Numbering: String, CaseIterable, Equatable, Sendable {
        case off, prefix, suffix

        public var displayName: String {
            switch self {
            case .off: "Нет"
            case .prefix: "В начале"
            case .suffix: "В конце"
            }
        }
    }

    public enum ChangeCase: String, CaseIterable, Equatable, Sendable {
        case none, lower, upper, title

        public var displayName: String {
            switch self {
            case .none: "Не менять"
            case .lower: "строчные"
            case .upper: "ПРОПИСНЫЕ"
            case .title: "С Заглавной"
            }
        }
    }

    public var find = ""
    public var replace = ""
    public var caseSensitive = false
    public var prefix = ""
    public var suffix = ""
    public var numbering: Numbering = .off
    public var numberingStart = 1
    public var numberingStep = 1
    public var numberingPad = 1
    public var changeCase: ChangeCase = .none

    public init() {}

    /// Правило ничего не делает. Такой план — ноль шагов, а не «переименовать
    /// всё в то же имя»: иначе кнопка в листе была бы активна на пустом
    /// правиле, и нажатие молча ничего бы не делало.
    public var isEmpty: Bool {
        find.isEmpty && prefix.isEmpty && suffix.isEmpty
            && numbering == .off && changeCase == .none
    }
}

/// Один шаг плана: что и во что переименовать, либо почему нельзя.
public struct RenameStep: Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case ok
        /// Причина человеческим текстом — лист показывает её красным.
        case conflict(String)
    }

    /// id — адрес источника: он уникален в плане и нужен таблице превью.
    public var id: URL { item.url }
    public let item: FileItem
    public let newName: String
    public let status: Status

    /// Итоговый адрес: та же папка, новое имя.
    public var target: URL {
        item.url.deletingLastPathComponent().appendingPathComponent(newName)
    }
}

/// Чистый движок плана: применяет правила и находит конфликты, ничего не
/// записывая на диск. Отсюда живое превью на каждое изменение полей и
/// тестируемость без UI.
public enum BatchRenamePlan {
    public static func build(items: [FileItem], rule: BatchRenameRule) -> [RenameStep] {
        guard !rule.isEmpty else { return [] }

        let fm = FileManager.default
        let matched = matching(items, rule: rule)
        // Адреса источников в нижнем регистре: файловая система обычно
        // регистронезависима, и «A.txt» с «a.txt» на диске не уживутся.
        //
        // Собираются по отфильтрованным, а не по всем поданным: отсеянный
        // фильтром файл никуда не уедет, его имя занято по-настоящему, и цель,
        // совпавшая с ним, обязана стать конфликтом.
        let sources = Set(matched.map { $0.url.path.lowercased() })

        var steps = matched.enumerated().map { index, item in
            let name = transformedName(for: item, rule: rule, index: index)
            return RenameStep(item: item, newName: name, status: status(of: name))
        }

        // Конфликты вычисляются до выполнения, а не по ходу записи: лист
        // показывает причину до нажатия кнопки, а конфликтный шаг просто
        // пропускается.

        // Два результата с одним именем конфликтуют оба, а не только второй:
        // иначе первый молча занял бы имя, а человек увидел бы это только
        // после выполнения.
        var nameCount: [String: Int] = [:]
        for step in steps where step.status == .ok {
            nameCount[step.target.path.lowercased(), default: 0] += 1
        }
        for (index, step) in steps.enumerated() where step.status == .ok {
            if nameCount[step.target.path.lowercased(), default: 0] > 1 {
                steps[index] = RenameStep(
                    item: step.item, newName: step.newName,
                    status: .conflict("Два файла получат имя «\(step.newName)»")
                )
            }
        }

        // Имя занято файлом на диске. Имена других переименовываемых
        // источников занятыми не считаются: к моменту записи цели они уже
        // уедут на свои новые имена, и считать их занятыми запрещало бы
        // законный обмен a↔b.
        for (index, step) in steps.enumerated() where step.status == .ok {
            let target = step.target
            guard target != step.item.url else { continue }
            if fm.fileExists(atPath: target.path), !sources.contains(target.path.lowercased()) {
                steps[index] = RenameStep(
                    item: step.item, newName: step.newName,
                    status: .conflict("Имя «\(step.newName)» уже занято")
                )
            }
        }

        return steps
    }

    /// «Найти» отбирает набор, а не только задаёт подстроку для замены: не
    /// совпавший объект в план не попадает вовсе. Иначе он оставался бы в
    /// превью с прежним именем, считался в «Будет переименовано» и занимал
    /// номер при нумерации, хотя человек его не выбирал правилом.
    ///
    /// Сравнение — по имени без расширения, по тому же тексту, к которому
    /// применяется замена: отбор по полному имени пропустил бы «Найти: jpg»,
    /// где менять в базе нечего, и строка попала бы в план не изменившись.
    ///
    /// Пустое «Найти» не фильтрует ничего — правило «префикс ко всем
    /// выделенным» обязано работать без отбора.
    private static func matching(_ items: [FileItem], rule: BatchRenameRule) -> [FileItem] {
        guard !rule.find.isEmpty else { return items }
        return items.filter {
            $0.url.deletingPathExtension().lastPathComponent
                .range(of: rule.find, options: rule.caseSensitive ? [] : .caseInsensitive) != nil
        }
    }

    /// Все правила применяются к имени без расширения, расширение
    /// сохраняется всегда: «замена IMG → Отпуск» не должна превращать
    /// «IMG_4021.jpg» в файл без типа.
    ///
    /// Порядок фиксирован — замена → регистр → префикс/суффикс → нумерация:
    /// нумерация обязана видеть финальное имя, иначе «Отпуск 01» при
    /// суффиксе, применённом после номера, превратился бы в «01 Отпуск».
    ///
    /// index — позиция в отфильтрованном наборе, а не в поданном: считай по
    /// поданному, и в превью появились бы пропуски номеров на месте
    /// отсеянных фильтром объектов, которых человек не задавал.
    private static func transformedName(for item: FileItem, rule: BatchRenameRule, index: Int) -> String {
        var base = item.url.deletingPathExtension().lastPathComponent
        if !rule.find.isEmpty {
            base = base.replacingOccurrences(
                of: rule.find, with: rule.replace,
                options: rule.caseSensitive ? [] : .caseInsensitive
            )
        }
        switch rule.changeCase {
        case .none: break
        case .lower: base = base.lowercased()
        case .upper: base = base.uppercased()
        case .title: base = base.capitalized
        }
        base = rule.prefix + base + rule.suffix
        if rule.numbering != .off {
            let number = rule.numberingStart + index * rule.numberingStep
            let formatted = String(format: "%0\(max(rule.numberingPad, 1))d", number)
            base = rule.numbering == .prefix ? formatted + base : base + formatted
        }
        let ext = item.url.pathExtension
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static func status(of name: String) -> RenameStep.Status {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Пустое имя ловим и в виде «.txt»: база пуста, осталось одно
        // расширение, — а это скрытый файл без имени, а не имя.
        guard !trimmed.isEmpty, !name.hasPrefix(".") else { return .conflict("Пустое имя") }
        guard !name.contains("/"), !name.contains(":") else {
            return .conflict("Имя не должно содержать «/» и «:»")
        }
        return .ok
    }
}

/// Итог выполнения пакета: сколько удалось и какие шаги не прошли.
public struct BatchRenameSummary: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public let name: String
        public let reason: String
    }

    /// Шагов к выполнению (без конфликтных — те пропущены заранее).
    public let total: Int
    public let succeeded: Int
    public let failures: [Failure]
}

/// Выполняет план. Запись — через FileOperations (переименование = move в
/// той же папке), а не свой moveItem: там уже валидация имени и проверка
/// занятости.
public struct BatchRenameExecutor {
    private let operations = FileOperations()
    private let fm = FileManager.default

    public init() {}

    /// Конфликтные шаги пропускаются — их лист уже показал красным.
    /// Ошибка посередине не прерывает пакет: прервать всё из-за одного файла
    /// значило бы оставить половину переименованной без объяснения, какой
    /// именно шаг не прошёл.
    public func execute(_ steps: [RenameStep]) -> BatchRenameSummary {
        // Шаги «в то же имя» готовы без диска — и в проверку пересечения их
        // включать нельзя: источник совпадает с целью по определению, и
        // двухпроходный режим включался бы всегда.
        let changed = steps.filter { $0.status == .ok && $0.target != $0.item.url }
        let unchangedCount = steps.count - changed.count

        let sources = Set(changed.map { $0.item.url.path.lowercased() })
        let targets = Set(changed.map { $0.target.path.lowercased() })

        // Если целевые имена пересекаются с исходными (обмен a↔b, сдвиг
        // нумерации), прямой проход затёр бы файл, чьё имя ещё нужно другому
        // шагу. Поэтому сначала всё уезжает на временные уникальные имена,
        // потом — на целевые.
        let needsTwoPasses = !sources.isDisjoint(with: targets)

        var succeeded = unchangedCount
        var failures: [BatchRenameSummary.Failure] = []

        if needsTwoPasses {
            var staged: [(step: RenameStep, temp: URL)] = []
            for step in changed {
                let temp = step.item.url.deletingLastPathComponent()
                    .appendingPathComponent(".pathway-rename-\(UUID().uuidString)")
                do {
                    try fm.moveItem(at: step.item.url, to: temp)
                    staged.append((step, temp))
                } catch {
                    failures.append(.init(name: step.item.name, reason: describe(error)))
                }
            }
            for (step, temp) in staged {
                do {
                    _ = try operations.rename(temp, to: step.newName)
                    succeeded += 1
                } catch {
                    failures.append(.init(name: step.item.name, reason: describe(error)))
                }
            }
        } else {
            for step in changed {
                do {
                    _ = try operations.rename(step.item.url, to: step.newName)
                    succeeded += 1
                } catch {
                    failures.append(.init(name: step.item.name, reason: describe(error)))
                }
            }
        }

        return BatchRenameSummary(total: steps.count, succeeded: succeeded, failures: failures)
    }

    private func describe(_ error: any Error) -> String {
        if let operationError = error as? FileOperationError {
            switch operationError {
            case .invalidName: return "Недопустимое имя"
            case .nameAlreadyExists: return "Имя уже занято"
            }
        }
        return error.localizedDescription
    }
}
