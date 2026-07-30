import Foundation
import Testing
@testable import PathwayCore

@Suite("Пакетное переименование")
struct BatchRenameTests {

    /// Элемент списка из адреса на диске. Путь берём из withTempDir как есть —
    /// DirectoryLoader здесь не участвует, канонизировать нечему.
    private func item(_ url: URL, isDirectory: Bool = false) -> FileItem {
        FileItem(url: url, name: url.lastPathComponent, isDirectory: isDirectory)
    }

    private func makeFile(_ dir: URL, _ name: String, _ content: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    // MARK: - Правила

    @Test("замена находит подстроку без учёта регистра по умолчанию")
    func replacementIsCaseInsensitiveByDefault() throws {
        try withTempDir { dir in
            let items = [item(try makeFile(dir, "IMG_1.txt")), item(try makeFile(dir, "img_2.txt"))]
            var rule = BatchRenameRule()
            rule.find = "img"
            rule.replace = "Фото"

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            #expect(steps.map(\.newName) == ["Фото_1.txt", "Фото_2.txt"])
        }
    }

    @Test("замена с учётом регистра не трогает другое написание")
    func replacementRespectsCaseWhenAsked() throws {
        try withTempDir { dir in
            let items = [item(try makeFile(dir, "IMG_1.txt")), item(try makeFile(dir, "img_2.txt"))]
            var rule = BatchRenameRule()
            rule.find = "IMG"
            rule.replace = "Фото"
            rule.caseSensitive = true

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            #expect(steps.map(\.newName) == ["Фото_1.txt", "img_2.txt"])
        }
    }

    @Test("замена не трогает расширение, а не переписывает имя целиком")
    func replacementKeepsExtension() throws {
        try withTempDir { dir in
            let items = [item(try makeFile(dir, "IMG_1.jpg"))]
            var rule = BatchRenameRule()
            rule.find = "IMG"
            rule.replace = "Фото"

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            #expect(steps.map(\.newName) == ["Фото_1.jpg"])
        }
    }

    @Test("префикс и суффикс добавляются к имени без расширения")
    func prefixAndSuffixWrapBaseName() throws {
        try withTempDir { dir in
            let items = [item(try makeFile(dir, "a.txt"))]
            var rule = BatchRenameRule()
            rule.prefix = "x-"
            rule.suffix = "-y"

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            #expect(steps.map(\.newName) == ["x-a-y.txt"])
        }
    }

    @Test("нумерация-префикс с паддингом и шагом")
    func numberingPrefixWithPaddingAndStep() throws {
        try withTempDir { dir in
            let items = [item(try makeFile(dir, "a.txt")), item(try makeFile(dir, "b.txt"))]
            var rule = BatchRenameRule()
            rule.numbering = .prefix
            rule.numberingStart = 5
            rule.numberingStep = 5
            rule.numberingPad = 3

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            #expect(steps.map(\.newName) == ["005a.txt", "010b.txt"])
        }
    }

    @Test("нумерация идёт после остальных правил, а не до")
    func numberingAppliesLast() throws {
        try withTempDir { dir in
            let items = [item(try makeFile(dir, "IMG_1.jpg"))]
            var rule = BatchRenameRule()
            rule.find = "IMG"
            rule.replace = "Отпуск"
            rule.numbering = .suffix

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            #expect(steps.map(\.newName) == ["Отпуск_11.jpg"])
        }
    }

    @Test("порядок нумерации совпадает с порядком входного массива, а не с сортировкой имён")
    func numberingFollowsInputOrder() throws {
        try withTempDir { dir in
            // Поданы «b, a» — как отсортировал список человек, так и нумеруем.
            let items = [item(try makeFile(dir, "b.txt")), item(try makeFile(dir, "a.txt"))]
            var rule = BatchRenameRule()
            rule.numbering = .prefix

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            #expect(steps.map(\.newName) == ["1b.txt", "2a.txt"])
        }
    }

    @Test("смена регистра применяется к имени без расширения")
    func changeCaseKeepsExtensionUntouched() throws {
        try withTempDir { dir in
            let items = [item(try makeFile(dir, "Ab.txt"))]
            var rule = BatchRenameRule()
            rule.changeCase = .upper

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            #expect(steps.map(\.newName) == ["AB.txt"])
        }
    }

    @Test("комбинация правил применяется в фиксированном порядке")
    func combinedRulesApplyInFixedOrder() throws {
        try withTempDir { dir in
            let items = [item(try makeFile(dir, "IMG_1.jpg")), item(try makeFile(dir, "IMG_2.jpg"))]
            var rule = BatchRenameRule()
            rule.find = "IMG"
            rule.replace = "Фото"
            rule.prefix = "["
            rule.numbering = .suffix
            rule.numberingPad = 2

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            #expect(steps.map(\.newName) == ["[Фото_101.jpg", "[Фото_202.jpg"])
        }
    }

    @Test("пустое правило даёт ноль шагов")
    func emptyRuleProducesNoSteps() throws {
        try withTempDir { dir in
            let items = [item(try makeFile(dir, "a.txt")), item(try makeFile(dir, "b.txt"))]

            let steps = BatchRenamePlan.build(items: items, rule: BatchRenameRule())

            // Иначе кнопка «Переименовать» была бы активна на пустом правиле,
            // и нажатие молча ничего бы не делало.
            #expect(steps.isEmpty)
        }
    }

    // MARK: - Конфликты

    @Test("конфликт: имя занято файлом вне выделения")
    func conflictWithFileOutsideSelection() throws {
        try withTempDir { dir in
            _ = try makeFile(dir, "c.txt")
            let items = [item(try makeFile(dir, "a.txt"))]
            var rule = BatchRenameRule()
            rule.find = "a"
            rule.replace = "c"

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            guard case .conflict = steps[0].status else {
                Issue.record("ожидался конфликт, получен \(steps[0].status)")
                return
            }
        }
    }

    @Test("имя переименовываемого источника занятым не считается")
    func sourceNamesAreNotOccupied() throws {
        try withTempDir { dir in
            // Цепочка a → ab → abb: цель «ab.txt» занята источником, который
            // сам уедет, — конфликта быть не должно, иначе обмен имён был бы
            // невозможен в принципе.
            let items = [item(try makeFile(dir, "a.txt")), item(try makeFile(dir, "ab.txt"))]
            var rule = BatchRenameRule()
            rule.find = "a"
            rule.replace = "ab"

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            #expect(steps.allSatisfy { $0.status == .ok })
        }
    }

    @Test("конфликт: два результата совпали, помечаются оба")
    func duplicateResultsConflictBoth() throws {
        try withTempDir { dir in
            let items = [item(try makeFile(dir, "a1.txt")), item(try makeFile(dir, "a2.txt"))]
            var rule = BatchRenameRule()
            rule.find = "2"
            rule.replace = "1"

            let steps = BatchRenamePlan.build(items: items, rule: rule)

            // Помечаются оба, а не только второй: иначе первый молча занял бы
            // имя, и человек увидел бы это только после выполнения.
            #expect(steps.allSatisfy {
                if case .conflict = $0.status { return true }
                return false
            })
        }
    }

    @Test("конфликт: недопустимое имя")
    func invalidNameConflicts() throws {
        try withTempDir { dir in
            let empty = [item(try makeFile(dir, "a.txt"))]
            var emptyRule = BatchRenameRule()
            emptyRule.find = "a"

            let emptySteps = BatchRenamePlan.build(items: empty, rule: emptyRule)
            guard case .conflict = emptySteps[0].status else {
                Issue.record("пустое имя должно быть конфликтом")
                return
            }

            var slashRule = BatchRenameRule()
            slashRule.prefix = "папка/"
            let slashSteps = BatchRenamePlan.build(items: empty, rule: slashRule)
            guard case .conflict = slashSteps[0].status else {
                Issue.record("имя со слэшем должно быть конфликтом")
                return
            }
        }
    }

    // MARK: - Выполнение

    @Test("цепочка a → ab → abb выполняется на диске, а не теряет файл")
    func overlappingTargetsExecuteInTwoPasses() throws {
        try withTempDir { dir in
            let a = try makeFile(dir, "a.txt", "A")
            let ab = try makeFile(dir, "ab.txt", "AB")
            var rule = BatchRenameRule()
            rule.find = "a"
            rule.replace = "ab"

            let steps = BatchRenamePlan.build(items: [item(a), item(ab)], rule: rule)
            let summary = BatchRenameExecutor().execute(steps)

            // Прямой проход записал бы «ab.txt» поверх ещё нужного источника.
            #expect(summary.failures.isEmpty)
            #expect(summary.succeeded == 2)
            #expect(!FileManager.default.fileExists(atPath: a.path))
            #expect(try String(contentsOf: dir.appendingPathComponent("ab.txt"), encoding: .utf8) == "A")
            #expect(try String(contentsOf: dir.appendingPathComponent("abb.txt"), encoding: .utf8) == "AB")
        }
    }

    @Test("после выполнения не остаётся временных файлов")
    func noTempFilesLeftBehind() throws {
        try withTempDir { dir in
            let a = try makeFile(dir, "a.txt")
            let ab = try makeFile(dir, "ab.txt")
            var rule = BatchRenameRule()
            rule.find = "a"
            rule.replace = "ab"

            let steps = BatchRenamePlan.build(items: [item(a), item(ab)], rule: rule)
            _ = BatchRenameExecutor().execute(steps)

            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(names.allSatisfy { !$0.hasPrefix(".pathway-rename-") })
        }
    }

    @Test("ошибка посередине пропускает шаг, а не прерывает пакет")
    func failureSkipsStepAndReportsSummary() throws {
        try withTempDir { dir in
            let a = try makeFile(dir, "a.txt")
            let b = try makeFile(dir, "b.txt")
            var rule = BatchRenameRule()
            rule.prefix = "x-"
            let steps = BatchRenamePlan.build(items: [item(a), item(b)], rule: rule)

            // Файл исчез между построением плана и выполнением.
            try FileManager.default.removeItem(at: b)

            let summary = BatchRenameExecutor().execute(steps)

            #expect(summary.total == 2)
            #expect(summary.succeeded == 1)
            #expect(summary.failures.count == 1)
            #expect(summary.failures[0].name == "b.txt")
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x-a.txt").path))
        }
    }

    // MARK: - Команда

    @MainActor
    private func makeState(path: URL) -> AppState {
        let suite = "batchrename.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let tabs = TabsModel(path: path, store: TabsStore(defaults: defaults))
        return AppState(tabs: tabs, favorites: FavoritesStore(defaults: defaults))
    }

    @MainActor
    @Test("команда доступна от двух выделенных и просит интерфейс открыть лист")
    func commandNeedsTwoSelectedAndAsksInterface() async throws {
        try await withTempDirAsync { dir in
            let state = makeState(path: dir)
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("b.txt"))
            state.browser.reloadAsync()
            await state.browser.waitForLoad()
            let command = CommandRegistry[.batchRename]

            // Для одного есть F2 — инлайн-редактор удобнее листа.
            let first = state.browser.items.first { $0.name == "a.txt" }!.url
            state.browser.pane.selection = [first]
            #expect(!command.isEnabled(state))

            state.browser.selectAll()
            #expect(command.isEnabled(state))

            command.run(state)
            #expect(state.pendingBatchRename?.count == 2)
        }
    }
}
