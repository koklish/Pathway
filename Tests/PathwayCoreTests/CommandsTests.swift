import Foundation
import Testing
@testable import PathwayCore

@MainActor
@Suite("CommandRegistry — реестр команд")
struct CommandsTests {

    /// Состояние с временной папкой и изолированным избранным: тесты не должны
    /// цепляться за домашнюю папку и настройки пользователя.
    private func makeState(path: URL) -> AppState {
        let suite = "commands.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppState(path: path, favorites: FavoritesStore(defaults: defaults))
    }

    /// URL элемента из загруженного списка. Брать его из items обязательно:
    /// DirectoryLoader канонизирует путь (/var → /private/var), и склеенный
    /// вручную URL не совпал бы с ним при сравнении.
    private func url(of name: String, in state: AppState) -> URL {
        state.browser.items.first { $0.name == name }!.url
    }

    // MARK: - Том только для чтения

    @Test("на томе только для чтения команды записи недоступны")
    func writeCommandsAreDisabledOnReadOnlyVolume() async throws {
        try await withTempDirAsync { dir in
            let state = makeState(path: dir)
            try Data("текст".utf8).write(to: dir.appendingPathComponent("файл.txt"))
            state.browser.reloadAsync()
            await state.browser.waitForLoad()
            state.browser.pane.selection = [url(of: "файл.txt", in: state)]
            state.browser.copy()

            state.browser.isReadOnlyVolume = true

            // Вырезать тоже пишет: исходник удаляется при вставке.
            for id in [CommandID.newFolder, .rename, .moveToTrash, .paste, .compress, .cut] {
                #expect(!CommandRegistry[id].isEnabled(state), "\(id) должна быть недоступна")
            }
        }
    }

    @Test("на томе только для чтения чтение остаётся доступным")
    func readCommandsStayEnabledOnReadOnlyVolume() async throws {
        try await withTempDirAsync { dir in
            let state = makeState(path: dir)
            try Data("текст".utf8).write(to: dir.appendingPathComponent("файл.txt"))
            state.browser.reloadAsync()
            await state.browser.waitForLoad()
            state.browser.pane.selection = [url(of: "файл.txt", in: state)]

            state.browser.isReadOnlyVolume = true

            // Копирование с тома — это чтение, и ровно в нём смысл сценария.
            for id in [CommandID.copy, .open, .revealInFinder, .selectAll] {
                #expect(CommandRegistry[id].isEnabled(state), "\(id) должна остаться доступной")
            }
        }
    }

    @Test("список пишущих команд совпадает с тем, что гасит isEnabled")
    func writesToDiskMatchesEnabledRule() async throws {
        try await withTempDirAsync { dir in
            let state = makeState(path: dir)
            try Data("текст".utf8).write(to: dir.appendingPathComponent("файл.txt"))
            state.browser.reloadAsync()
            await state.browser.waitForLoad()
            state.browser.pane.selection = [url(of: "файл.txt", in: state)]
            state.browser.copy()

            // Набор writesToDisk используется контекстным меню, а isEnabled —
            // главным. Разойдись они, пункт был бы живым в одном меню и мёртвым
            // в другом.
            let enabledBefore = CommandID.allCases.filter { CommandRegistry[$0].isEnabled(state) }
            state.browser.isReadOnlyVolume = true
            let enabledAfter = CommandID.allCases.filter { CommandRegistry[$0].isEnabled(state) }

            #expect(Set(enabledBefore).subtracting(enabledAfter) == CommandRegistry.writesToDisk)
        }
    }

    @Test("на обычном томе команды записи доступны")
    func writeCommandsStayEnabledOnWritableVolume() async throws {
        try await withTempDirAsync { dir in
            let state = makeState(path: dir)
            try Data("текст".utf8).write(to: dir.appendingPathComponent("файл.txt"))
            state.browser.reloadAsync()
            await state.browser.waitForLoad()
            state.browser.pane.selection = [url(of: "файл.txt", in: state)]

            #expect(state.browser.isReadOnlyVolume == false)
            #expect(CommandRegistry[.newFolder].isEnabled(state))
            #expect(CommandRegistry[.rename].isEnabled(state))
            #expect(CommandRegistry[.moveToTrash].isEnabled(state))
        }
    }

    // MARK: - Целостность реестра

    @Test("каждая команда описана ровно один раз")
    func everyCommandIsDescribedOnce() {
        let ids = CommandRegistry.all.map(\.id)

        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == Set(CommandID.allCases))
    }

    @Test("шорткаты не конфликтуют между собой")
    func shortcutsAreUnique() {
        let shortcuts = CommandRegistry.all.compactMap(\.shortcut)

        for (index, shortcut) in shortcuts.enumerated() {
            let duplicates = shortcuts[(index + 1)...].filter { $0 == shortcut }
            #expect(duplicates.isEmpty, "шорткат \(shortcut) назначен дважды")
        }
    }

    @Test("у каждой команды непустой заголовок")
    func everyCommandHasTitle() {
        for command in CommandRegistry.all {
            #expect(!command.title.isEmpty)
        }
    }

    // MARK: - Доступность

    @Test("без выделения команды над файлами недоступны")
    func selectionCommandsDisabledWithoutSelection() throws {
        try withTempDir { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("file.txt"))
            let state = makeState(path: dir)
            state.browser.reload()

            for id in [CommandID.copy, .cut, .moveToTrash, .rename, .open, .compress] {
                #expect(!CommandRegistry[id].isEnabled(state), "\(id.rawValue) должна быть недоступна")
            }
            for id in [CommandID.newFolder, .refresh, .toggleHiddenFiles, .revealInFinder] {
                #expect(CommandRegistry[id].isEnabled(state), "\(id.rawValue) должна быть доступна")
            }
        }
    }

    @Test("с выделением команды над файлами доступны")
    func selectionCommandsEnabledWithSelection() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: file)
            let state = makeState(path: dir)
            state.browser.reload()

            state.browser.pane.selection = [state.browser.items[0].url]

            for id in [CommandID.copy, .cut, .moveToTrash, .rename, .open] {
                #expect(CommandRegistry[id].isEnabled(state), "\(id.rawValue) должна быть доступна")
            }
        }
    }

    @Test("во время ввода текста файловые команды гасятся")
    func fileCommandsDisabledWhileEditingText() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: file)
            let state = makeState(path: dir)
            state.browser.reload()
            state.browser.pane.selection = [file]

            state.isEditingText = true

            // Только те, которых текстовое поле не перехватывает.
            for id in [CommandID.moveToTrash, .rename, .newFolder, .open] {
                #expect(!CommandRegistry[id].isEnabled(state), "\(id.rawValue) должна гаснуть при вводе текста")
            }
        }
    }

    @Test("выбор буферного пункта мышью при вводе текста файлов не трогает")
    func pasteboardRunIsInertWhileEditingText() throws {
        try withTempDir { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("b.txt"))
            let state = makeState(path: dir)
            state.browser.reload()
            state.browser.pane.selection = []

            state.isEditingText = true
            // Проверяем на «Выбрать всё»: его эффект виден прямо в модели, а
            // copy/cut ушли бы в системный буфер, где и без нас что-то лежит.
            CommandRegistry[.selectAll].run(state)

            // Пункт живой ради шортката, но клик по нему мышью при открытом
            // диалоге не должен доставать до списка файлов: responder chain
            // защищает только клавиши, а мышь идёт прямо в run.
            #expect(state.browser.pane.selection.isEmpty)
        }
    }

    @Test("буферные команды при вводе текста остаются живыми — их берёт поле")
    func pasteboardCommandsStayEnabledWhileEditingText() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: file)
            let state = makeState(path: dir)
            state.browser.reload()
            state.browser.pane.selection = [file]
            state.browser.copy()

            state.isEditingText = true

            // Погашенный пункт меню перехватывает шорткат и никуда его не
            // отдаёт: ⌘C переставал доходить до NSTextField, и в полях
            // диалога копирование не работало вовсе. Доставку по responder
            // chain обеспечивает AppKit — пункт для этого должен быть живым.
            for id in [CommandID.copy, .cut, .paste, .selectAll] {
                #expect(CommandRegistry[id].isEnabled(state), "\(id.rawValue) нужна текстовому полю")
            }
        }
    }

    @Test("переименование доступно только для одного элемента")
    func renameRequiresSingleSelection() throws {
        try withTempDir { dir in
            let first = dir.appendingPathComponent("a.txt")
            let second = dir.appendingPathComponent("b.txt")
            try Data("x".utf8).write(to: first)
            try Data("x".utf8).write(to: second)
            let state = makeState(path: dir)
            state.browser.reload()

            state.browser.pane.selection = [first, second]

            #expect(!CommandRegistry[.rename].isEnabled(state))
        }
    }

    @Test("распаковка доступна только для выделенного архива")
    func extractRequiresArchive() throws {
        try withTempDir { dir in
            let text = dir.appendingPathComponent("note.txt")
            let archive = dir.appendingPathComponent("data.zip")
            try Data("x".utf8).write(to: text)
            try Data("x".utf8).write(to: archive)
            let state = makeState(path: dir)
            state.browser.reload()

            state.browser.pane.selection = [url(of: "note.txt", in: state)]
            #expect(!CommandRegistry[.extractHere].isEnabled(state))

            state.browser.pane.selection = [url(of: "data.zip", in: state)]
            #expect(CommandRegistry[.extractHere].isEnabled(state))
        }
    }

    @Test("навигация следует истории панели")
    func navigationFollowsHistory() async throws {
        try await withTempDirAsync { dir in
            let sub = dir.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            let state = makeState(path: dir)
            state.browser.reload()

            #expect(!CommandRegistry[.goBack].isEnabled(state))
            #expect(!CommandRegistry[.goForward].isEnabled(state))

            state.browser.navigate(to: sub)
            await state.browser.waitForLoad()

            #expect(CommandRegistry[.goBack].isEnabled(state))
            #expect(!CommandRegistry[.goForward].isEnabled(state))
        }
    }

    @Test("в корне файловой системы переход вверх недоступен")
    func goUpDisabledAtRoot() {
        let state = makeState(path: URL(fileURLWithPath: "/"))

        #expect(!CommandRegistry[.goUp].isEnabled(state))
    }

    // MARK: - Исполнение

    @Test("копирование через команду делает то же, что метод модели")
    func copyMatchesModel() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: file)
            let state = makeState(path: dir)
            state.browser.reload()
            state.browser.pane.selection = [file]

            CommandRegistry[.copy].run(state)

            #expect(state.browser.canPaste)
        }
    }

    @Test("вырезание помечает выделенные файлы")
    func cutMarksSelection() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: file)
            let state = makeState(path: dir)
            state.browser.reload()
            state.browser.pane.selection = [file]

            CommandRegistry[.cut].run(state)

            #expect(state.browser.pane.isCut(file))
        }
    }

    @Test("выбрать всё выделяет весь список")
    func selectAllSelectsEverything() throws {
        try withTempDir { dir in
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
            try Data("x".utf8).write(to: dir.appendingPathComponent("b.txt"))
            let state = makeState(path: dir)
            state.browser.reload()

            CommandRegistry[.selectAll].run(state)

            #expect(state.browser.pane.selection.count == 2)
        }
    }

    @Test("переименование не выполняет операцию, а просит интерфейс открыть редактор")
    func renameRequestsEditorInsteadOfActing() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: file)
            let state = makeState(path: dir)
            state.browser.reload()
            state.browser.pane.selection = [file]

            CommandRegistry[.rename].run(state)

            #expect(state.pendingRename == file)
            #expect(FileManager.default.fileExists(atPath: file.path), "файл не должен меняться")
        }
    }

    @Test("архивация просит интерфейс открыть диалог")
    func compressRequestsDialog() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: file)
            let state = makeState(path: dir)
            state.browser.reload()
            let selected = state.browser.items[0].url
            state.browser.pane.selection = [selected]

            CommandRegistry[.compress].run(state)

            #expect(state.pendingCompress?.map(\.url) == [selected])
        }
    }

    @Test("переход к папке просит интерфейс сфокусировать адресную строку")
    func editPathRequestsFocus() {
        let state = makeState(path: FileManager.default.temporaryDirectory)

        CommandRegistry[.editPath].run(state)

        #expect(state.pendingEditPath)
    }

    @Test("удаление в корзину убирает файл из списка")
    func moveToTrashRemovesFile() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: file)
            let state = makeState(path: dir)
            state.browser.reload()
            state.browser.pane.selection = [file]

            CommandRegistry[.moveToTrash].run(state)

            #expect(state.browser.items.isEmpty)
        }
    }

    @Test("переключатель скрытых файлов меняет настройку")
    func toggleHiddenFilesFlipsSetting() {
        let state = makeState(path: FileManager.default.temporaryDirectory)

        CommandRegistry[.toggleHiddenFiles].run(state)

        #expect(state.showHiddenFiles)
    }

    @Test("избранное переключается для текущей папки")
    func toggleFavoriteUsesCurrentFolder() throws {
        try withTempDir { dir in
            let state = makeState(path: dir)
            state.browser.reload()

            CommandRegistry[.toggleFavorite].run(state)

            #expect(state.folderActions.isFavorite(dir))
        }
    }
}
