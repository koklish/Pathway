import Foundation

/// Заметки к выпуску, разобранные в список пунктов для поповера.
///
/// Тело релиза приходит с GitHub как сырой Markdown, а `release.sh` собирает его
/// из сообщений коммитов после прошлого тега — то есть формат предсказуем ровно
/// настолько, насколько предсказуемы сообщения коммитов, и полагаться на него
/// нельзя. Отсюда разбор, а не рендеринг: `AttributedString(markdown:)` умеет
/// жирный и курсив, но списки схлопывает в один абзац без маркеров — как раз то,
/// ради чего поповер и затевался.
///
/// Разбор чистый и живёт в Core, чтобы проверяться тестами: во вью такую логику
/// пришлось бы щупать глазами на настоящем релизе.
public enum ReleaseNotes {
    /// Блок заметок одной версии.
    public struct Section: Equatable, Sendable {
        /// Версия из заголовка `## 1.1.5`. nil — пункты до первого заголовка
        /// либо заголовок не с номером («## Что нового»).
        public let version: AppVersion?
        public let items: [String]
    }

    /// Разбирает тело релиза в пункты списка.
    ///
    /// Маркер (`-`, `*`, `•`) снимается, а строки без него всё равно становятся
    /// пунктами: `release.sh` пишет заголовки коммитов без маркеров вовсе, и
    /// отбрасывать их значило бы показать пустой поповер на типичном релизе.
    public static func parse(_ notes: String) -> [String] {
        notes
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { item(from: $0) }
            .filter { !$0.isEmpty }
    }

    /// Разбирает накопительное тело релиза в блоки версий новее установленной.
    ///
    /// Тело содержит не только свои изменения, но и блоки предыдущих выпусков:
    /// приложение спрашивает GitHub только про `/releases/latest`, и коллега,
    /// перешагнувший через версию, о пропущенной иначе не узнал бы никогда.
    /// Показывать её целиком нельзя по обратной причине — обновляющийся с
    /// предыдущей версии видел бы всю историю проекта вместо одной новой строки.
    ///
    /// Сравнение строгое: секция, равная установленной версии, отбрасывается —
    /// иначе пользователь видел бы собственную версию в списке предстоящих
    /// изменений.
    public static func sections(_ notes: String, after current: AppVersion) -> [Section] {
        var sections: [Section] = []
        // nil до первого заголовка: пункты преамбулы принадлежат безымянной
        // секции, а не следующей за ними версии.
        var version: AppVersion?
        var items: [String] = []

        /// Закрывает набранную секцию. Пустая отбрасывается: заголовок без
        /// пунктов — след правки тела руками, и пустой блок с одним номером
        /// выглядел бы как потерянный текст.
        func flush() {
            defer { items = [] }
            guard !items.isEmpty else { return }
            // Секция без распознанной версии остаётся всегда: тело могли
            // отредактировать и заголовок не поставить, а отбросив такие пункты,
            // мы показали бы пустой поповер при доступном обновлении.
            guard let version else {
                sections.append(Section(version: nil, items: items))
                return
            }
            guard version > current else { return }
            sections.append(Section(version: version, items: items))
        }

        for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                flush()
                var heading = trimmed
                while heading.hasPrefix("#") { heading.removeFirst() }
                // Заголовок не с номером («## Что нового») даёт секцию без
                // версии, а не выброшенный текст: сам заголовок теряется, но
                // его пункты остаются видны.
                version = AppVersion(heading.trimmingCharacters(in: .whitespaces))
                continue
            }
            let text = item(from: line)
            if !text.isEmpty { items.append(text) }
        }
        flush()

        return sections
    }

    /// Снимает с строки маркер списка. Общий для плоского и секционного разбора,
    /// чтобы они не разошлись в том, что считают пунктом.
    private static func item(from line: Substring) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        // Заголовки Markdown («## Что нового») — оформление тела релиза,
        // а не пункт списка: решётки снимаются, текст остаётся.
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• ", "+ "] where text.hasPrefix(marker) {
            text.removeFirst(marker.count)
            break
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
