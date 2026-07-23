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
    /// Разбирает тело релиза в пункты списка.
    ///
    /// Маркер (`-`, `*`, `•`) снимается, а строки без него всё равно становятся
    /// пунктами: `release.sh` пишет заголовки коммитов без маркеров вовсе, и
    /// отбрасывать их значило бы показать пустой поповер на типичном релизе.
    public static func parse(_ notes: String) -> [String] {
        notes
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
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
            .filter { !$0.isEmpty }
    }
}
