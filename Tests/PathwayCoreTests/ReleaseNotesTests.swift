import Testing

@testable import PathwayCore

@Suite("Разбор заметок к выпуску")
struct ReleaseNotesTests {
    @Test("снимает маркеры списка")
    func stripsBulletMarkers() {
        let notes = """
        - Умные папки и сохранённые поиски
        * Работа с архивами прямо в проводнике
        • Индикаторы синхронизации
        """

        #expect(ReleaseNotes.parse(notes) == [
            "Умные папки и сохранённые поиски",
            "Работа с архивами прямо в проводнике",
            "Индикаторы синхронизации",
        ])
    }

    @Test("строки без маркеров тоже становятся пунктами")
    func keepsUnmarkedLines() {
        // release.sh собирает заметки из заголовков коммитов, а те пишутся без
        // маркеров вовсе. Отбрасывай такие строки — и на типичном релизе
        // поповер оказался бы пустым.
        let notes = """
        Корректировки фокуса поля адреса
        Закрытие приложения изолировано главным актором
        """

        #expect(ReleaseNotes.parse(notes) == [
            "Корректировки фокуса поля адреса",
            "Закрытие приложения изолировано главным актором",
        ])
    }

    @Test("снимает решётки заголовков, а не выбрасывает строку целиком")
    func stripsHeadingHashes() {
        #expect(ReleaseNotes.parse("## Что нового") == ["Что нового"])
    }

    @Test("пропускает пустые строки")
    func skipsBlankLines() {
        let notes = """
        - Первый

        \u{0020}
        - Второй
        """

        #expect(ReleaseNotes.parse(notes) == ["Первый", "Второй"])
    }

    @Test("пустые заметки дают пустой список, а не пункт из пустой строки")
    func emptyNotesGiveEmptyList() {
        #expect(ReleaseNotes.parse("").isEmpty)
        #expect(ReleaseNotes.parse("\n\n  \n").isEmpty)
    }

    @Test("снимает маркер один раз, а не съедает дефис внутри текста")
    func stripsMarkerOnlyOnce() {
        // «- - Первый» — это пункт с текстом «- Первый», а не «Первый»: жадное
        // снятие маркеров съело бы дефис, который автор написал осознанно.
        #expect(ReleaseNotes.parse("- - Первый") == ["- Первый"])
    }
}

@Suite("Заметки к выпуску по версиям")
struct ReleaseNotesSectionsTests {
    /// Накопительное тело релиза, какое собирает release.sh.
    private let accumulated = """
    ## 1.1.5
    - Иконка сервера во вкладках
    ## 1.1.4
    - Навигация больше не раскрывается автоматически
    - Папки в иерархии теперь на Вашем языке
    ## 1.1.3
    - Список изменений больше не обрезается
    ## 1.1.2
    - Путь копировать ещё проще
    """

    private func version(_ string: String) -> AppVersion {
        AppVersion(string)!
    }

    @Test("режет тело на секции по заголовкам версий")
    func splitsByVersionHeadings() {
        let sections = ReleaseNotes.sections(accumulated, after: version("1.1.1"))

        #expect(sections.map(\.version) == [
            version("1.1.5"), version("1.1.4"), version("1.1.3"), version("1.1.2"),
        ])
        #expect(sections[1].items == [
            "Навигация больше не раскрывается автоматически",
            "Папки в иерархии теперь на Вашем языке",
        ])
    }

    @Test("оставляет только версии новее установленной, а не всю историю")
    func dropsVersionsUpToCurrent() {
        let sections = ReleaseNotes.sections(accumulated, after: version("1.1.4"))

        #expect(sections.map(\.version) == [version("1.1.5")])
        #expect(sections.first?.items == ["Иконка сервера во вкладках"])
    }

    @Test("отбрасывает версию, равную установленной, а не только младшие")
    func dropsEqualVersion() {
        // Строгое «новее» — иначе свою же версию пользователь увидел бы в списке
        // изменений, будто её ещё предстоит установить.
        let sections = ReleaseNotes.sections("## 1.1.5\n- Одно", after: version("1.1.5"))

        #expect(sections.isEmpty)
    }

    @Test("оставляет промежуточные пропущенные версии, а не только свежую")
    func keepsSkippedVersions() {
        // Обновляясь с 1.1.2 сразу на 1.1.5, коллега должен узнать и про 1.1.4
        // с 1.1.3: приложение спрашивает GitHub только про последний релиз, и
        // другого места про пропущенное узнать нет.
        let sections = ReleaseNotes.sections(accumulated, after: version("1.1.2"))

        #expect(sections.map(\.version) == [version("1.1.5"), version("1.1.4"), version("1.1.3")])
    }

    @Test("пункты до первого заголовка остаются секцией без версии")
    func keepsPreamble() {
        // Тело релиза владелец мог отредактировать руками и заголовок не
        // поставить: отбросив такие пункты, поповер оказался бы пуст при
        // доступном обновлении.
        let sections = ReleaseNotes.sections("- Без заголовка\n## 1.1.4\n- Старое", after: version("1.1.4"))

        #expect(sections.count == 1)
        #expect(sections[0].version == nil)
        #expect(sections[0].items == ["Без заголовка"])
    }

    @Test("заголовок с нечисловым текстом даёт секцию без версии, а не выброшенную строку")
    func keepsNonVersionHeading() {
        let sections = ReleaseNotes.sections("## Что нового\n- Пункт", after: version("1.1.4"))

        #expect(sections.count == 1)
        #expect(sections[0].version == nil)
        #expect(sections[0].items == ["Пункт"])
    }

    @Test("тело без заголовков даёт одну секцию со всеми пунктами")
    func headinglessBodyGivesSingleSection() {
        let sections = ReleaseNotes.sections("- Первый\n- Второй", after: version("1.1.4"))

        #expect(sections.count == 1)
        #expect(sections[0].version == nil)
        #expect(sections[0].items == ["Первый", "Второй"])
    }

    @Test("заголовок без пунктов не даёт пустой секции")
    func skipsEmptySection() {
        let sections = ReleaseNotes.sections("## 1.1.5\n## 1.1.6\n- Есть", after: version("1.1.4"))

        #expect(sections.map(\.version) == [version("1.1.6")])
    }

    @Test("тело целиком старее установленного даёт пустой список")
    func allOlderGivesEmpty() {
        #expect(ReleaseNotes.sections(accumulated, after: version("2.0.0")).isEmpty)
    }
}
