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

            for id in [CommandID.copy, .cut, .paste, .moveToTrash, .rename, .newFolder, .open, .selectAll] {
                #expect(!CommandRegistry[id].isEnabled(state), "\(id.rawValue) должна гаснуть при вводе текста")
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
