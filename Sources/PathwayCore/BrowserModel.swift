import AppKit
import Foundation
import Observation

/// Сегмент пути в адресной строке.
public struct Breadcrumb: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
}

/// Распаковка наткнулась на зашифрованный архив — интерфейс должен спросить пароль.
public struct PasswordRequest: Hashable, Sendable {
    public let archive: URL
    public let destination: URL
    /// true — пароль уже вводили, и он не подошёл.
    public let wasWrong: Bool
}

/// Связывает навигацию, чтение папки и файловые операции для одной панели.
@Observable
@MainActor
public final class BrowserModel {
    public let pane: PaneState
    public private(set) var items: [FileItem] = []
    public var errorMessage: String?
    /// Результат последней git-операции; вью показывает его тостом и
    /// сбрасывает в nil. Отдельно от errorMessage: тот открывает модальное
    /// окно, а обмен с сервером прерывать работу не должен — человек и так
    /// смотрит на список файлов, ради которого операцию затевал.
    public var toast: Toast? {
        didSet {
            // Таймер заводится присваиванием, а не каждым местом, где тост
            // рождается: мест пять, и забытый вызов оставил бы сообщение
            // висеть навсегда.
            if toast != nil { startToastTimer() }
        }
    }
    /// Сколько держать тост на экране. Замыкание, чтобы тесты не ждали
    /// настоящие секунды: восемь секунд ради одной проверки — половина всего
    /// прогона.
    public var toastDuration: (Toast.Kind) -> Duration = { kind in
        // Ошибка длиннее по тексту, и исчезни она за тот же срок, человек
        // остался бы с ощущением, что что-то мелькнуло, а что — неизвестно.
        kind == .success ? .seconds(3) : .seconds(8)
    }
    private var toastTask: Task<Void, Never>?
    public var showHiddenFiles = false
    public var operationProgress: Double?
    /// Название идущей операции для статус-бара («Архивация…», «Распаковка…»).
    public private(set) var operationTitle: String?
    public private(set) var passwordRequest: PasswordRequest?
    /// Выделение ждёт подтверждения безвозвратного удаления (сетевой том,
    /// Корзины на нём нет). Обратный канал «Core просит UI»: вью показывает
    /// алерт и зовёт deletePermanently() либо cancelPermanentDelete().
    public var pendingPermanentDelete: [URL]?

    /// true, пока идёт чтение папки — для индикатора в интерфейсе.
    public private(set) var isLoading = false

    /// Репозиторий, внутри которого находится текущая папка; nil — снаружи.
    ///
    /// Отвечает на «где сейчас я», в отличие от колонки «Ветка», отвечающей
    /// на «какая ветка у каждой из этих папок». Поэтому и живёт отдельно от
    /// items: во вложенной папке репозитория строк с веткой может не быть
    /// вовсе, а индикатор обязан её показывать.
    public private(set) var currentRepository: RepositoryState?

    /// Файл, к которому таблица должна прокрутиться. Обратный канал «Core
    /// просит UI»: прокрутка принадлежит NSScrollView, из модели её не сделать.
    /// Вью сбрасывает поле, выполнив запрос.
    public var revealRequest: URL?

    /// Файл, ожидающий выделения после загрузки папки.
    private var pendingReveal: URL?

    /// Открыт инлайн-редактор имени. Поднимает его вью на время правки.
    ///
    /// Внешнее обновление при поднятом флаге не трогает список: перезагрузка
    /// таблицы уводит фокус из поля, и набранное имя пропадает под руками.
    public var isRenaming = false

    /// Текущая папка лежит на томе только для чтения — команды записи погашены.
    ///
    /// Спрашиваем файловую систему, а не смотрим на схему адреса: FTP через
    /// NetFS монтируется read-only, но так же ведут себя образ диска,
    /// заблокированная флешка и чужая папка без прав.
    ///
    /// internal(set), а не private(set): тестам нужно поставить флаг без
    /// настоящего тома, монтировать который они не могут.
    public internal(set) var isReadOnlyVolume = false

    /// Папка панели сменилась. Вкладки сохраняют по нему сессию: путь меняется
    /// внутри модели, и заметить это снаружи иначе нечем — наблюдать за pane.path
    /// из TabsModel значило бы держать по подписке на каждую вкладку.
    ///
    /// Не @Observable-свойство, а замыкание: вызов должен случиться сразу, а не
    /// на следующем проходе рендера, иначе закрытие приложения между сменой
    /// папки и отрисовкой потеряло бы последний путь.
    var didChangeFolder: (() -> Void)?

    private let loader = DirectoryLoader()
    private let operations = FileOperations()
    private let archiver = ArchiveService()
    /// Текущая операция с архивом — одна за раз, с возможностью отмены.
    private var operationTask: Task<Void, Never>?
    private let pasteboard: PasteboardService
    private let cache = DirectoryCache()
    /// Сортировку раздаёт TabsModel — она общая для всех вкладок и переживает
    /// перезапуск. Здесь она ведомая: private(set), чтобы её нельзя было
    /// поменять мимо TabsModel, разведя вкладки между собой.
    public private(set) var sortKey = SortSettings.defaultKey
    public private(set) var sortAscending = SortSettings.defaultAscending
    /// Текущая загрузка: при быстром переключении папок предыдущая отменяется,
    /// иначе медленный сетевой ответ перезапишет уже открытую папку.
    private var loadTask: Task<Void, Never>?
    private let watcher: any DirectoryWatching
    private let git: GitService
    private var repositoryTask: Task<Void, Never>?
    /// Обновление по событию от файловой системы. Отдельная задача, а не loadTask:
    /// отмена чтения при закрытии вкладки не должна зависеть от того, пришло ли
    /// событие, и наоборот.
    private var refreshTask: Task<Void, Never>?
    /// Второй проход обновления — метаданные добавившихся записей.
    private var metadataTask: Task<Void, Never>?

    public init(
        path: URL,
        pasteboard: PasteboardService = PasteboardService(),
        watcher: any DirectoryWatching = DirectoryWatcher(),
        git: GitService = GitService()
    ) {
        self.pane = PaneState(path: path)
        self.pasteboard = pasteboard
        self.watcher = watcher
        self.git = git
    }

    public var breadcrumbs: [Breadcrumb] {
        var crumbs = [Breadcrumb(url: URL(fileURLWithPath: "/"), name: "Этот Мас")]
        var accumulated = ""
        for component in pane.path.pathComponents.dropFirst() {
            accumulated += "/" + component
            let url = URL(fileURLWithPath: accumulated)
            crumbs.append(Breadcrumb(url: url, name: Self.displayName(for: url)))
        }
        return crumbs
    }

    /// Имя сегмента так, как его показывает Finder: локализованное, если система его переводит.
    private static func displayName(for url: URL) -> String {
        SystemFolderNames.displayNameAskingSystem(for: url)
    }

    public var statusText: String {
        let folders = items.filter(\.isDirectory).count
        var text = "Папок: \(folders), файлов: \(items.count - folders)"
        if !pane.selection.isEmpty {
            text += " · Выделено: \(pane.selection.count)"
        }
        return text
    }

    // MARK: - Контекст команд

    /// Выделенные элементы в порядке показа. Команды работают с FileItem,
    /// а pane.selection хранит только URL.
    public var selectedItems: [FileItem] {
        items.filter { pane.selection.contains($0.url) }
    }

    /// Объект, к которому относится команда: единственный выделенный элемент,
    /// иначе — сама открытая папка.
    public var commandTarget: URL {
        pane.selection.count == 1 ? (pane.selection.first ?? pane.path) : pane.path
    }

    /// Папка для команд, которым нужна именно папка (Терминал, избранное):
    /// выделенная папка либо текущая.
    public var commandFolder: URL {
        guard let item = selectedItems.first, selectedItems.count == 1, item.isDirectory else {
            return pane.path
        }
        return item.url
    }

    public var canPaste: Bool {
        !pasteboard.readURLs().isEmpty
    }

    /// Идёт операция с архивом — вторую начинать нельзя.
    public var isBusy: Bool { operationTitle != nil }

    public func selectAll() {
        pane.selection = Set(items.map(\.url))
    }

    // MARK: - Загрузка и навигация

    /// Синхронная загрузка — для тестов и файловых операций, где нужен готовый результат.
    public func reload() {
        do {
            let loaded = sorted(try loader.load(directory: pane.path, showHidden: showHiddenFiles))
            cache.store(loaded, for: pane.path, showHidden: showHiddenFiles)
            items = loaded
        } catch {
            items = []
            errorMessage = Self.describe(error, at: pane.path)
        }
    }

    /// Загрузка для интерфейса: не блокирует главный поток.
    ///
    /// Порядок такой, чтобы окно оставалось живым на медленных дисках:
    /// сначала кэш (мгновенно), затем имена из фонового потока, затем метаданные.
    public func reloadAsync() {
        let directory = pane.path
        let showHidden = showHiddenFiles

        // Синхронно, до первого await: иначе команды записи успели бы
        // побывать доступными на томе, который их не примет.
        isReadOnlyVolume = Self.isReadOnly(directory)
        // Один раз на папку, а не на строку: это свойство тома, и запрос на
        // каждую запись был бы тем самым сетевым обращением, которого
        // проверка и позволяет избежать.
        let isLocal = Self.isOnLocalVolume(directory)

        // Уже открытую папку показываем сразу, не дожидаясь диска.
        if let cached = cache.items(for: directory, showHidden: showHidden) {
            items = sorted(cached)
        }
        let hadCache = !items.isEmpty && cache.items(for: directory, showHidden: showHidden) != nil

        // Отдельной задачей от загрузки списка: git status на большом
        // репозитории стоит сотни миллисекунд, и ожидание его задержало бы
        // отрисовку файлов ради справочной строки.
        refreshRepositoryInBackground()

        loadTask?.cancel()
        loadTask = Task { [loader] in
            if !hadCache { isLoading = true }
            defer { isLoading = false }

            do {
                // Обход каталога — самая дорогая часть, уводим её с главного потока.
                let names = try await Task.detached(priority: .userInitiated) {
                    try loader.loadNames(directory: directory, showHidden: showHidden)
                }.value

                guard !Task.isCancelled, pane.path == directory else { return }
                items = sorted(names)

                // Метаданные добираем следом: список уже виден и кликабелен.
                let detailed = await Task.detached(priority: .utility) {
                    loader.loadMetadata(for: names, isLocalVolume: isLocal)
                }.value

                guard !Task.isCancelled, pane.path == directory else { return }
                cache.store(detailed, for: directory, showHidden: showHidden)
                items = sorted(detailed)
            } catch {
                guard !Task.isCancelled, pane.path == directory else { return }
                items = []
                errorMessage = Self.describe(error, at: directory)
            }

            // Слежение ставим по готовому списку, а не в начале загрузки:
            // событие, пришедшее на недочитанную папку, дало бы дифф против
            // неполного списка и «потеряло» бы ещё не показанные файлы.
            guard !Task.isCancelled, pane.path == directory else { return }
            applyPendingReveal()
            startWatching(directory)
        }
    }

    /// Переходит в папку файла и выделяет его.
    ///
    /// Нужен переходу из выдачи поиска: сама по себе навигация оставила бы
    /// человека в папке с сотней файлов и без подсказки, какой из них нашёлся.
    ///
    /// Выделение отложено, а не выставлено здесь же: список грузится
    /// асинхронно, и `selection` до его прихода указывал бы на URL, которого
    /// в `items` ещё нет. Вдобавок `pane.navigate` очищает выделение сам.
    public func navigate(to directory: URL, revealing file: URL) {
        pendingReveal = file
        // Уже в нужной папке — навигации не будет, а с ней и загрузки, которая
        // выполнила бы запрос. Тогда выделяем сразу.
        guard PaneState.normalize(directory) != pane.path else {
            applyPendingReveal()
            return
        }
        navigate(to: directory)
    }

    /// Выполняет отложенное выделение, если файл дошёл до списка.
    ///
    /// Промах не считается ошибкой: файл могли удалить между поиском и
    /// переходом, и папка всё равно открылась — это лучше, чем алерт.
    private func applyPendingReveal() {
        guard let file = pendingReveal else { return }
        pendingReveal = nil
        let target = PaneState.normalize(file)
        guard items.contains(where: { $0.url == target }) else { return }
        pane.selection = [target]
        revealRequest = target
    }

    // MARK: - Внешние изменения

    /// Подписывается на изменения папки. Повторный вызов переставляет слежение:
    /// отдельный stop не нужен, у наблюдателя всегда одна папка.
    private func startWatching(_ directory: URL) {
        watcher.start(directory) { [weak self] change in
            self?.applyExternalChange(change)
        }
    }

    /// Обновляет список по событию файловой системы — диффом, а не перезагрузкой.
    ///
    /// Полный reloadAsync здесь стоил бы на сетевой папке сотен миллисекунд, а
    /// событие приходит на каждое чужое создание файла. Поэтому перечитываются
    /// только имена (дешёвый обход через d_type), а метаданные — лишь у записей,
    /// которых в списке не было.
    private func applyExternalChange(_ change: DirectoryChange) {
        // Редактор имени перезагрузка таблицы сбила бы, а своя операция и так
        // заканчивается вызовом reload — второе обновление поверх неё лишнее.
        guard !isRenaming, !isBusy else { return }

        let directory = pane.path
        let showHidden = showHiddenFiles

        refreshTask?.cancel()
        refreshTask = Task { [loader] in
            // .utility, а не .userInitiated: обновления никто не ждал, и оно не
            // должно соперничать с чтением папки, в которую пользователь перешёл.
            guard let names = try? await Task.detached(priority: .utility, operation: {
                try loader.loadNames(directory: directory, showHidden: showHidden)
            }).value else {
                // Папку удалили или том отвалился. Алерт здесь неуместен: человек
                // этого обновления не просил, а список пусть остаётся прежним.
                return
            }

            guard !Task.isCancelled, pane.path == directory else { return }
            merge(names, hasModifications: change.hasModifications, in: directory, showHidden: showHidden)
        }
    }

    /// Сливает свежий состав папки с показанным списком, сохраняя прочитанные метаданные.
    private func merge(_ names: [FileItem], hasModifications: Bool, in directory: URL, showHidden: Bool) {
        let known = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0) })
        let merged = names.map { fresh in
            // Уцелевшая запись сохраняет размер и дату; при ItemModified они
            // устарели, и запись отправляется во второй проход как новая.
            guard !hasModifications, let existing = known[fresh.url] else { return fresh }
            return existing
        }

        // Выделение чистим от исчезнувших: иначе команды работали бы с URL,
        // которых в папке уже нет.
        let present = Set(merged.map(\.url))
        pane.selection = pane.selection.intersection(present)

        items = sorted(merged)

        let incomplete = merged.filter { !$0.metadataLoaded }
        guard !incomplete.isEmpty else {
            cache.store(merged, for: directory, showHidden: showHidden)
            return
        }
        loadMetadataAfterMerge(in: directory, showHidden: showHidden)
    }

    /// Второй проход: размеры и даты для записей, попавших в список без них.
    private func loadMetadataAfterMerge(in directory: URL, showHidden: Bool) {
        let pending = items
        let isLocal = Self.isOnLocalVolume(directory)
        metadataTask?.cancel()
        metadataTask = Task { [loader] in
            let detailed = await Task.detached(priority: .utility) {
                loader.loadMetadata(for: pending, isLocalVolume: isLocal)
            }.value

            guard !Task.isCancelled, pane.path == directory else { return }
            // Только полные записи попадают в кэш — там не должно быть заготовок.
            cache.store(detailed, for: directory, showHidden: showHidden)
            items = sorted(detailed)
        }
    }

    /// Перечитывает папку, как после внешнего изменения. Зовётся при возврате
    /// на вкладку: пока она была фоновой, слежение за ней не велось.
    public func refreshAfterReturn() {
        applyExternalChange(DirectoryChange(hasModifications: true))
    }

    /// Снимает слежение — вкладка ушла в фон или окно потеряло фокус.
    public func stopWatching() {
        watcher.stop()
    }

    /// Возвращает слежение за текущей папкой.
    public func resumeWatching() {
        startWatching(pane.path)
    }

    /// Ждёт применения внешнего обновления — для тестов.
    public func waitForRefresh() async {
        await refreshTask?.value
    }

    /// Ждёт второго прохода за метаданными — для тестов.
    public func waitForMetadata() async {
        await metadataTask?.value
    }

    /// Лежит ли папка на томе только для чтения.
    ///
    /// Значение кэшируется системой в момент монтирования, так что вызов
    /// дешёвый и уместен до первого await. Недоступную папку считаем
    /// доступной для записи: ошибку тогда покажет сама операция, с текстом
    /// про настоящую причину, а не про мнимый read-only.
    private static func isReadOnly(_ directory: URL) -> Bool {
        (try? directory.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    public func navigate(to url: URL) {
        pane.navigate(to: url)
        didChangeFolder?()
        reloadAsync()
    }

    public func goBack() {
        pane.goBack()
        didChangeFolder?()
        reloadAsync()
    }

    public func goForward() {
        pane.goForward()
        didChangeFolder?()
        reloadAsync()
    }

    public func goUp() {
        pane.goUp()
        didChangeFolder?()
        reloadAsync()
    }

    /// Ждёт завершения текущей фоновой загрузки. Нужно тестам и коду,
    /// которому важен готовый список сразу после перехода.
    public func waitForLoad() async {
        await loadTask?.value
    }

    /// Снимает незавершённое чтение папки. Зовётся при закрытии вкладки:
    /// loadTask держит модель сильной ссылкой через захват в замыкании, и
    /// чтение медленной сетевой папки продержало бы закрытую вкладку в
    /// памяти до своего конца.
    public func cancelLoad() {
        loadTask?.cancel()
        refreshTask?.cancel()
        metadataTask?.cancel()
        watcher.stop()
    }

    public func open(_ item: FileItem) {
        if item.isDirectory {
            navigate(to: item.url)
        } else if ArchiveService.isArchive(item.url) {
            extract(item)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// Подпапки для дерева в сайдбаре. Недоступные папки — просто пустой список:
    /// раскрытие узла не должно показывать алерт.
    public func subdirectories(of url: URL) -> [FileItem] {
        let contents = (try? loader.loadNames(directory: url, showHidden: showHiddenFiles)) ?? []
        return contents.filter(\.isDirectory)
    }

    /// Подпапки для дерева, прочитанные вне главного потока.
    ///
    /// Раскрытие узла на сетевом диске стоит сотни миллисекунд — синхронное чтение
    /// подвесило бы весь сайдбар.
    public func subdirectoriesAsync(of url: URL) async -> [FileItem] {
        let showHidden = showHiddenFiles
        return await Task.detached(priority: .userInitiated) { [loader] in
            let contents = (try? loader.loadNames(directory: url, showHidden: showHidden)) ?? []
            let directories = contents.filter(\.isDirectory)
            // В дереве сетевые тома не показываем: ими управляют из секции «Сеть»,
            // а здесь они были бы вторым, неуправляемым вхождением того же диска.
            // В списке файлов /Volumes при этом остаётся полным.
            return directories.filter { !Self.isNetworkVolume($0.url) }
        }.value
    }

    /// Точка монтирования сетевого тома: /Volumes/… на неместной файловой системе.
    /// nonisolated — проверка чистая и вызывается из фонового чтения каталога.
    private nonisolated static func isNetworkVolume(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().path == "/Volumes" else { return false }
        return (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
    }

    // MARK: - Сортировка и отображение

    /// Ставит сортировку и перестраивает список.
    ///
    /// Зовётся из TabsModel, а не из вью напрямую: сортировка общая для всех
    /// вкладок, и выставленная здесь по месту развела бы их между собой.
    public func applySort(_ sort: SortSettings) {
        sortKey = sort.key
        sortAscending = sort.ascending
        items = sorted(items)
    }

    private func sorted(_ list: [FileItem]) -> [FileItem] {
        Self.sorted(list, by: SortSettings(key: sortKey, ascending: sortAscending))
    }

    /// Чистая сортировка: без диска и без состояния модели, поэтому проверяется
    /// тестами напрямую — items закрыт на запись, и подсунуть модели список
    /// «как после быстрого прохода» иначе было бы нечем.
    static func sorted(_ list: [FileItem], by settings: SortSettings) -> [FileItem] {
        let sortKey = settings.key
        let sortAscending = settings.ascending

        // Первый проход отдаёт одни имена: размеров и дат ещё нет ни у кого, и
        // сортировка по ним поставила бы список в порядке выдачи readdir, а
        // после второго прохода перетасовала бы его целиком под курсором.
        // По имени первый список хотя бы упорядочен понятным образом.
        //
        // Показывать пустой список до метаданных нельзя: ради мгновенного
        // появления имён на сетевом диске трёхступенчатая загрузка и сделана.
        let sortsByName = sortKey == "name" || list.allSatisfy { !$0.metadataLoaded }

        return list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            guard !sortsByName else {
                let byName = a.name.localizedStandardCompare(b.name) == .orderedAscending
                // Направление уважаем и здесь: иначе «по имени по убыванию»
                // до прихода метаданных показывал бы обратный порядок.
                return sortKey == "name" && !sortAscending ? !byName : byName
            }
            // Ветка — до общей инверсии направления: папки без неё обязаны
            // остаться внизу в обе стороны. Смысл сортировки по ветке в том,
            // чтобы сгруппировать проекты, а всплывшие наверх полэкрана пустых
            // строк отодвинули бы их за край экрана.
            if sortKey == "branch", (a.branch == nil) != (b.branch == nil) {
                return a.branch != nil
            }

            let result: Bool
            switch sortKey {
            case "size": result = a.size < b.size
            case "modified": result = (a.modificationDate ?? .distantPast) < (b.modificationDate ?? .distantPast)
            case "kind": result = a.url.pathExtension.localizedStandardCompare(b.url.pathExtension) == .orderedAscending
            case "branch":
                // При равных ветках — по имени, в отличие от прочих колонок.
                // Смысл этой сортировки в группировке: половина проектов стоит
                // на main, и без разрешения ничьей они выстроились бы в порядке
                // выдачи readdir, то есть случайно на глаз.
                let left = a.branch ?? ""
                let right = b.branch ?? ""
                if left == right {
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                result = left.localizedStandardCompare(right) == .orderedAscending
            default: result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return sortAscending ? result : !result
        }
    }

    public func text(for item: FileItem, column: String) -> String {
        switch column {
        case "size":
            return item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        case "modified":
            guard let date = item.modificationDate else { return "—" }
            return date.formatted(date: .abbreviated, time: .shortened)
        case "kind":
            return Self.kindLabel(for: item)
        case "branch":
            // Пусто, а не «—»: прочерк читался бы как «ветка есть, но неизвестна»,
            // тогда как папка просто не репозиторий.
            //
            // Колонку рисует чип, а не этот текст: он остаётся текстовым
            // представлением ветки для всего, что работает со строками.
            return item.branch ?? ""
        default:
            return item.name
        }
    }

    private static func kindLabel(for item: FileItem) -> String {
        if item.isDirectory { return "Папка" }
        let ext = item.url.pathExtension
        return ext.isEmpty ? "Документ" : ext.uppercased()
    }

    // MARK: - Git

    /// Перечитывает состояние репозитория текущей папки.
    public func refreshRepository() async {
        refreshRepositoryInBackground()
        await repositoryTask?.value
    }

    private func refreshRepositoryInBackground() {
        let directory = pane.path

        repositoryTask?.cancel()
        repositoryTask = Task { [git] in
            // Поиск корня — обращения к диску вверх по пути, поэтому вне
            // главного потока: на сетевом томе они не мгновенны.
            let root = await Task.detached(priority: .utility) {
                GitRepository.root(containing: directory)
            }.value

            // Обе защиты, как и в reloadAsync: они не дублируют друг друга.
            // Отмена кооперативна и уже запущенный Task.detached её не видит —
            // отсюда проверка пути; но при обновлении той же папки (а его зовёт
            // каждый fetch/pull/push) путь совпадает, и отменённая задача
            // перезаписала бы результат более свежей.
            guard !Task.isCancelled, pane.path == directory else { return }
            guard let root else {
                currentRepository = nil
                return
            }

            // Ветка из HEAD доступна сразу, счётчики — только после git status.
            // Показываем ветку не дожидаясь сети: на медленном сервере иначе
            // индикатор пустовал бы секундами.
            currentRepository = RepositoryState(root: root, branch: GitRepository.branch(at: root))

            let status = try? await git.status(at: root)
            guard !Task.isCancelled, pane.path == directory, let status else { return }
            currentRepository = RepositoryState(
                root: root,
                branch: status.branch ?? GitRepository.branch(at: root),
                ahead: status.ahead,
                behind: status.behind,
                isDirty: status.isDirty
            )
        }
    }

    // Необязательная цель — для контекстного меню списка: правый клик по
    // невыделенной строке действует на неё, и без явной цели операция ушла бы
    // в выделенный проект, то есть не туда, по чему человек кликнул. Без
    // аргумента цель прежняя, из gitTarget.
    public func gitFetch(at repository: URL? = nil) {
        runGit(title: "Получение изменений…", failure: "Не удалось получить изменения", at: repository) {
            [git] root in
            try await git.fetch(at: root)
        } toast: { result in
            // Итоговое отставание, а не прирост за этот запрос. Прирост врёт,
            // когда refs успел обновить кто-то другой — фоновый fetch среды
            // разработки, терминал или предыдущий Fetch отсюда же: разница
            // выходит нулевой, и тост говорит «Нового нет» прямо перед pull,
            // который принесёт коммиты. Спрашивают ведь «есть ли что
            // забирать», а не «сколько притащил именно этот вызов».
            let behind = result.after?.behind ?? 0
            return behind > 0 ? "На сервере \(Self.plural(behind, "новый коммит", "новых коммита", "новых коммитов"))" : "Нового нет"
        }
    }

    public func gitPull(at repository: URL? = nil) {
        runGit(title: "Загрузка изменений…", failure: "Не удалось загрузить изменения", at: repository) {
            [git] root in
            try await git.pull(at: root)
        } toast: { result in
            // По разнице HEAD, а не по счётчику «позади» до операции: тот
            // показал бы ноль, когда refs устарели, — и «Уже актуально»
            // появилось бы прямо про pull, принёсший чужие правки.
            let loaded = result.arrived
            return loaded > 0 ? "Загружено \(Self.plural(loaded, "коммит", "коммита", "коммитов"))" : "Уже актуально"
        }
    }

    public func gitPush(at repository: URL? = nil) {
        runGit(title: "Отправка изменений…", failure: "Не удалось отправить изменения", at: repository) {
            [git] root in
            try await git.push(at: root)
        } toast: { result in
            // Из состояния до операции: локальные коммиты git знает без сети,
            // и в отличие от «позади» этот счётчик устареть не может.
            let sent = result.before?.ahead ?? 0
            return sent > 0 ? "Отправлено \(Self.plural(sent, "коммит", "коммита", "коммитов"))" : "Нечего отправлять"
        }
    }

    public func gitSync(at repository: URL? = nil) {
        runGit(title: "Синхронизация…", failure: "Не удалось синхронизировать", at: repository) {
            [git] root in
            try await git.sync(at: root)
        } toast: { result in
            // Обе половины в одной строке: sync — одна операция, и два тоста
            // подряд вытеснили бы друг друга, показав только второй.
            // Пришедшее — по HEAD, отправленное — по счётчику до операции: у
            // каждой половины свой надёжный источник.
            let loaded = result.arrived
            let sent = result.before?.ahead ?? 0
            switch (loaded, sent) {
            case (0, 0): return "Уже актуально"
            case (0, _): return "Отправлено \(Self.plural(sent, "коммит", "коммита", "коммитов"))"
            case (_, 0): return "Загружено \(Self.plural(loaded, "коммит", "коммита", "коммитов"))"
            default: return "Загружено \(loaded), отправлено \(Self.plural(sent, "коммит", "коммита", "коммитов"))"
            }
        }
    }

    /// Кладёт в буфер имя ветки того репозитория, над которым работают команды.
    ///
    /// Имя, а не путь: строку вставляют в терминал или в описание задачи, и
    /// путь там не нужен. Буфер чистится внутри writeText — иначе URL от
    /// прошлого «Копировать» пережили бы запись, и «Вставить» скопировала бы
    /// сам файл.
    /// Читает список веток репозитория для меню и формы выбора.
    ///
    /// Возвращает результат, а не пишет в свойство: список нужен ровно на
    /// время показа меню, и хранимое свойство пришлось бы чистить при каждой
    /// смене папки, чтобы не показать ветки чужого проекта.
    public func gitBranches(at repository: URL? = nil) async -> [Branch] {
        guard let root = repository ?? gitTarget else { return [] }
        return (try? await git.branches(at: root)) ?? []
    }

    /// Переключает ветку и перечитывает папку.
    ///
    /// Перечитывает обязательно: смена ветки меняет не только имя в чипе, но и
    /// содержимое рабочего дерева — без обновления список показывал бы файлы
    /// прежней ветки.
    public func gitSwitch(to branch: Branch, at repository: URL? = nil) {
        runGit(
            title: "Переключение на \(branch.name)…",
            failure: "Не удалось переключить ветку",
            at: repository
        ) { [git] root in
            if branch.isRemote {
                try await git.switchToRemote(branch.name, at: root)
            } else {
                try await git.switchBranch(to: branch.name, at: root)
            }
            await MainActor.run { self.reloadAsync() }
        } toast: { _ in
            "Ветка \(branch.name)"
        }
    }

    public func gitCopyBranch(at repository: URL? = nil) {
        guard let root = repository ?? gitTarget,
              let branch = GitRepository.branch(at: root) else { return }
        pasteboard.writeText(branch)
    }

    /// Клонирует репозиторий в текущую папку.
    public func gitClone(from url: String, name: String) {
        let destination = pane.path
        // Не через runGit: клонировать нечего сравнивать — репозитория до
        // операции ещё нет, и снимок состояния взять неоткуда.
        startOperation(title: "Клонирование…", reportsErrorAsToast: "Не удалось клонировать") { [git] _ in
            try await git.clone(from: url, into: destination, name: name)
            await MainActor.run { self.toast = Toast(.success, "Репозиторий склонирован") }
        }
    }

    /// Репозиторий, над которым сработает операция.
    ///
    /// Репозиторий текущей папки имеет приоритет над выделенным: индикатор в
    /// адресной строке показывает именно его, и выделение вложенного проекта
    /// увело бы push не туда, куда человек смотрит.
    ///
    /// Выделенная папка нужна для главного сценария — стоя в папке с проектами,
    /// которая репозиторием не является, выбрать проект и обновить его. Без
    /// этой ветки все операции были бы там мертвы.
    public var gitTarget: URL? {
        if let root = currentRepository?.root { return root }
        let folder = commandFolder
        // Проверка дешёвая: одно обращение к уже показанной строке, обхода
        // вверх по пути здесь нет.
        return folder != pane.path && GitRepository.isRepository(folder) ? folder : nil
    }

    /// Выполняет операцию в корне репозитория.
    ///
    /// Именно в корне, а не в текущей папке: git работал бы и из вложенной,
    /// но клонирование и будущие пофайловые операции требуют явного корня,
    /// и один способ вычисления цели надёжнее двух.
    ///
    /// `toast` получает итог операции и возвращает текст успеха. Данными, а не
    /// выводом git: «Everything up-to-date» и «Receiving objects» — английские
    /// строки без гарантий формата, и разбор по ним ломался бы от версии.
    private func runGit(
        title: String,
        failure: String,
        at repository: URL? = nil,
        _ body: @escaping (URL) async throws -> Void,
        toast: @escaping (GitOperationResult) -> String
    ) {
        guard let root = repository ?? gitTarget else { return }
        // Снимки читаются тем же git.status, что и индикатор, но по корню
        // операции, а не из currentRepository: операция могла уйти в
        // кликнутый проект, а там индикатор показывает не его.
        startOperation(title: title, reportsErrorAsToast: failure) { [git] _ in
            let before = try? await git.status(at: root)
            let oldHead = try? await git.head(at: root)
            try await body(root)
            let after = try? await git.status(at: root)
            let newHead = try? await git.head(at: root)

            // Сколько коммитов реально легло в рабочее дерево. Считается по
            // HEAD, потому что счётчик «позади» к началу операции мог быть
            // любым: pull сам начинается с fetch и узнаёт о чужих коммитах
            // уже внутри себя.
            var arrived = 0
            if let oldHead, let newHead {
                arrived = (try? await git.commitCount(from: oldHead, to: newHead, at: root)) ?? 0
            }
            let result = GitOperationResult(before: before, after: after, arrived: arrived)

            await MainActor.run {
                self.toast = Toast(.success, toast(result))
                self.refreshRepositoryInBackground()
            }
        }
    }

    /// Согласует числительное с числом: «1 коммит», «3 коммита», «5 коммитов».
    ///
    /// Без этого тост читался бы машинным переводом — «Загружено 1 коммитов»
    /// заметно каждому, кто читает по-русски.
    private static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let hundred = count % 100
        let ten = count % 10
        if hundred >= 11 && hundred <= 14 { return "\(count) \(many)" }
        if ten == 1 { return "\(count) \(one)" }
        if ten >= 2 && ten <= 4 { return "\(count) \(few)" }
        return "\(count) \(many)"
    }

    // MARK: - Файловые операции

    public func createFolder() {
        run { try operations.createFolder(in: pane.path) }
    }

    /// Возвращает адрес созданного документа, чтобы вью открыл на нём
    /// инлайн-редактор; nil — операция не удалась, текст уже в errorMessage.
    @discardableResult
    public func createDocument(_ template: DocumentTemplate) -> URL? {
        var created: URL?
        run {
            created = try operations.createDocument(template, in: pane.path)
        }
        return created
    }

    public func rename(_ url: URL, to newName: String) {
        run { _ = try operations.rename(url, to: newName) }
    }

    /// Пакетное переименование из листа. Сводка с неудачами — в errorMessage,
    /// а не в отдельный канал: лист к этому моменту уже закрыт, и тексту
    /// больше некуда уйти.
    public func applyBatchRename(_ steps: [RenameStep]) {
        var summary: BatchRenameSummary?
        run {
            summary = BatchRenameExecutor().execute(steps)
        }
        guard let summary, !summary.failures.isEmpty else { return }
        var text = "Переименовано \(summary.succeeded) из \(summary.total)."
        text += "\nНе удалось: "
        text += summary.failures.map { "«\($0.name)» — \($0.reason)" }.joined(separator: "; ")
        errorMessage = text
    }

    public func copy() {
        guard !pane.selection.isEmpty else { return }
        pasteboard.write(Array(pane.selection), operation: .copy)
        pane.clearCut()
    }

    /// Кладёт в буфер готовую строку.
    ///
    /// Через тот же PasteboardService, что и остальные буферные операции:
    /// отдельный экземпляр во вью писал бы мимо того, что читает «Вставить».
    public func copyText(_ text: String) {
        pasteboard.writeText(text)
    }

    /// Кладёт в буфер заданные файлы, минуя выделение.
    ///
    /// Нужен выдаче поиска: там находки лежат в разных папках и выделением
    /// панели не описываются вовсе.
    public func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pasteboard.write(urls, operation: .copy)
        pane.clearCut()
    }

    /// Кладёт в буфер пути обычным текстом — чтобы вставить их в терминал или
    /// в переписку. `urls` передаёт контекстное меню, работающее от кликнутой
    /// строки; без него берётся выделение, а на пустом выделении — сама папка.
    ///
    /// Несколько путей разделяются переводом строки: так их принимает и
    /// оболочка, и любой текстовый редактор. Порядок — как в списке, а не как в
    /// `Set`, иначе две строки приходили бы в случайном порядке.
    public func copyPath(_ urls: [URL]? = nil) {
        let targets = urls ?? (pane.selection.isEmpty ? [pane.path] : selectedItems.map(\.url))
        guard !targets.isEmpty else { return }
        pasteboard.writeText(targets.map(\.path).joined(separator: "\n"))
    }

    public func cut() {
        guard !pane.selection.isEmpty else { return }
        let urls = Array(pane.selection)
        pasteboard.write(urls, operation: .move)
        pane.markCut(urls)
    }

    public func paste() {
        let urls = pasteboard.readURLs()
        guard !urls.isEmpty else { return }
        let operation = pasteboard.readOperation()
        run {
            if operation == .move {
                _ = try operations.move(urls, to: pane.path)
                pane.clearCut()
            } else {
                _ = try operations.copy(urls, to: pane.path)
            }
        }
    }

    public func copy(_ urls: [URL], to destination: URL) {
        cache.invalidate(destination)
        run { _ = try operations.copy(urls, to: destination) }
    }

    public func move(_ urls: [URL], to destination: URL) {
        cache.invalidate(destination)
        urls.forEach { cache.invalidate($0.deletingLastPathComponent()) }
        run { _ = try operations.move(urls, to: destination) }
    }

    public func moveSelectionToTrash() {
        let urls = Array(pane.selection)
        guard !urls.isEmpty else { return }
        // На сетевых томах Корзины нет: trashItem падает с «volume doesn't
        // have one». Как Finder, удаляем сразу и навсегда — но сначала
        // спрашиваем подтверждение: назад дороги нет.
        if let first = urls.first, !Self.isOnLocalVolume(first) {
            pendingPermanentDelete = urls
            return
        }
        run {
            try operations.moveToTrash(urls)
            pane.selection = []
        }
    }

    /// Подтверждённое безвозвратное удаление — для сетевых томов без Корзины.
    public func deletePermanently() {
        guard let urls = pendingPermanentDelete else { return }
        pendingPermanentDelete = nil
        run {
            try operations.deletePermanently(urls)
            pane.selection = []
        }
    }

    public func cancelPermanentDelete() {
        pendingPermanentDelete = nil
    }

    /// Лежит ли объект на местном томе. Неопределённость считаем местной:
    /// тогда пойдём через Корзину, и ошибка покажет настоящую причину,
    /// а необратимого удаления по ложному срабатыванию не случится.
    /// public: то же решение нужно контекстному меню — синхронное чтение
    /// веток на сетевом томе заблокировало бы главный поток до ответа сервера.
    public nonisolated static func isOnLocalVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
    }

    // MARK: - Архивы

    public func compress(items: [FileItem], format: ArchiveFormat, password: String?, name: String) {
        let urls = items.map(\.url)
        let directory = pane.path
        startOperation(title: "Архивация…") { [archiver] progress in
            _ = try await archiver.create(
                items: urls, format: format, password: password,
                archiveName: name, in: directory, progress: progress)
        }
    }

    /// Распаковывает архив; `directory == nil` — рядом с архивом.
    public func extract(_ item: FileItem, to directory: URL? = nil) {
        extractArchive(item.url, to: directory ?? item.url.deletingLastPathComponent(), password: nil)
    }

    /// Повтор распаковки с паролем, введённым в диалоге.
    public func submitPassword(_ password: String) {
        guard let request = passwordRequest else { return }
        passwordRequest = nil
        extractArchive(request.archive, to: request.destination, password: password)
    }

    public func cancelPasswordRequest() {
        passwordRequest = nil
    }

    public func cancelOperation() {
        operationTask?.cancel()
    }

    /// Ждёт завершения текущей операции с архивом — для тестов.
    public func waitForOperation() async {
        await operationTask?.value
    }

    // MARK: - Тосты

    /// Заводит отсчёт до исчезновения тоста, отменяя отсчёт прежнего.
    ///
    /// Отмена обязательна: таймер вытесненного тоста, досчитав, погасил бы уже
    /// показанный следующий — и тот пропал бы через мгновение после появления.
    /// Она же покрывает и закрытие вручную: следующий тост заводит свой отсчёт
    /// и тем снимает прежний, поэтому отменять его ещё и в dismissToast нечего.
    private func startToastTimer() {
        guard let current = toast else { return }
        let duration = toastDuration(current.kind)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.toast = nil
        }
    }

    /// Убирает тост по клику.
    public func dismissToast() {
        toast = nil
    }

    private func extractArchive(_ archive: URL, to destination: URL, password: String?) {
        startOperation(title: "Распаковка…") { [archiver] progress in
            do {
                _ = try await archiver.extract(
                    archive: archive, to: destination, password: password, progress: progress)
            } catch ArchiveError.passwordRequired {
                await MainActor.run {
                    self.passwordRequest = PasswordRequest(archive: archive, destination: destination, wasWrong: false)
                }
            } catch ArchiveError.wrongPassword {
                await MainActor.run {
                    self.passwordRequest = PasswordRequest(archive: archive, destination: destination, wasWrong: true)
                }
            }
        }
    }

    /// Запускает операцию с архивом в фоне: прогресс в статус-бар, ошибки в алерт,
    /// по завершении список перечитывается.
    /// `reportsErrorAsToast` — короткий текст неудачи вместо модального алерта.
    /// Задан только у git-операций: сбой обмена с сервером человек исправляет в
    /// терминале, а не в диалоге, и окно поверх списка файлов ему мешает. У
    /// файловых операций текст остаётся в errorMessage — там ошибка означает,
    /// что задуманное не случилось с конкретным файлом, и пропустить её нельзя.
    private func startOperation(
        title: String,
        reportsErrorAsToast: String? = nil,
        _ body: @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void
    ) {
        operationTitle = title
        operationProgress = 0
        operationTask = Task {
            do {
                try await body { value in
                    Task { @MainActor in self.operationProgress = value }
                }
            } catch is CancellationError {
                // Отмена — не ошибка.
            } catch {
                if let short = reportsErrorAsToast {
                    toast = Toast(.failure, short)
                } else {
                    errorMessage = Self.describe(error, at: pane.path)
                }
            }
            operationTitle = nil
            operationProgress = nil
            cache.invalidate(pane.path)
            reload()
        }
    }

    /// Выполняет операцию, показывает понятную ошибку и обновляет список.
    private func run(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = Self.describe(error, at: pane.path)
        }
        // Содержимое папки изменилось — кэш устарел, читаем заново.
        cache.invalidate(pane.path)
        reload()
    }

    // MARK: - Ошибки

    private static func describe(_ error: any Error, at path: URL) -> String {
        if let archiveError = error as? ArchiveError {
            switch archiveError {
            case .passwordRequired, .wrongPassword:
                return "Архив зашифрован — нужен пароль."
            case .encryptedUnsupported:
                return "Архив зашифрован. Системный распаковщик не поддерживает зашифрованные 7z и RAR."
            case .toolFailed(let message):
                return "Не удалось обработать архив. \(message)"
            }
        }
        if let operationError = error as? FileOperationError {
            switch operationError {
            case .invalidName:
                return "Недопустимое имя. Имя не может быть пустым или содержать «/» и «:»."
            case .nameAlreadyExists:
                return "Объект с таким именем уже существует в этой папке."
            }
        }
        let nsError = error as NSError
        switch nsError.code {
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return "Нет доступа к «\(path.lastPathComponent)». Выдайте приложению полный доступ к диску в Настройках → Конфиденциальность и безопасность."
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return "Папка «\(path.lastPathComponent)» больше не существует."
        case NSFileWriteOutOfSpaceError:
            return "Недостаточно места на диске."
        default:
            return nsError.localizedDescription
        }
    }
}
