import AppKit
import PathwayCore
import SwiftUI

/// Список находок поиска — подменяет список файлов, пока поиск открыт.
///
/// SwiftUI `List`, а не обёртка над `NSTableView` как в `FileListView`: там
/// таблица понадобилась ради сортировки по заголовкам, инлайн-редактора имени,
/// контекстного меню и drag & drop. Здесь ничего этого нет — строка,
/// подсветка и двойной клик, — а число находок ограничено сверху выдачей
/// поиска, не числом файлов на диске.
struct SearchResultsView: View {
    let search: SearchModel
    let model: BrowserModel
    @Environment(AppState.self) private var appState
    @State private var selection: SearchResult.ID?

    private var actions: FolderActions { appState.folderActions }

    var body: some View {
        VStack(spacing: 0) {
            if search.results.isEmpty {
                // Пока ищем — «пока ничего», а не «ничего не найдено»: второе
                // было бы неправдой, поиск ещё не закончен.
                emptyState(searching: search.isSearching)
            } else {
                list
            }
            // Строка хода — пока ищем; итог с числом находок — когда закончили.
            // Место одно и то же: иначе список дёргался бы по высоте в момент
            // завершения поиска.
            if search.isSearching {
                Divider()
                progressBar
            } else if !search.results.isEmpty {
                Divider()
                summaryBar
            }
            if !search.report.isComplete {
                Divider()
                reportBar
            }
        }
        // Биндинг с рабочим сеттером, а не .constant: закрытие алерта — Esc,
        // клик мимо — идёт мимо кнопки, и с константным биндингом errorMessage
        // остался бы непустым, а алерт всплывал бы снова. Тот же приём, что у
        // остальных алертов в MainWindow.
        .alert(
            "Не удалось открыть файл",
            isPresented: Binding(
                get: { search.errorMessage != nil },
                set: { if !$0 { search.dismissError() } }
            )
        ) {
            Button("Ясно") { search.dismissError() }
        } message: {
            Text(search.errorMessage ?? "")
        }
    }

    // MARK: - Список

    private var list: some View {
        List(search.results, selection: $selection) { result in
            SearchResultRow(result: result, root: search.root)
                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                // Ни contentShape, ни tag: List(data, selection:) назначает
                // строке идентификатор сам и сам обрабатывает попадания.
                //
                // simultaneousGesture, а не onTapGesture: последний
                // потребляет и одиночный клик, оставляя List без события
                // выделения.
                .simultaneousGesture(TapGesture(count: 2).onEnded { open(result) })
                // Меню действует на кликнутую строку, а не на выделенную, —
                // нативное поведение macOS, как в списке файлов.
                .contextMenu { menuItems(for: result) }
        }
        .listStyle(.inset)
        // Enter открывает выделенную находку — вторым способом к двойному
        // клику: до этого выдача была доступна только мышью.
        .onKeyPress(.return) {
            guard let result = selected else { return .ignored }
            open(result)
            return .handled
        }
    }

    /// Находка под курсором — по выделению.
    private var selected: SearchResult? {
        guard let selection else { return nil }
        return search.results.first { $0.id == selection }
    }

    // MARK: - Контекстное меню

    /// Состав зависит от рода находки: у записи архива нет своего места на
    /// диске, поэтому «Показать в Finder» и «Копировать» для неё бессмысленны —
    /// показывать и копировать нечего, пока файл не извлечён.
    @ViewBuilder
    private func menuItems(for result: SearchResult) -> some View {
        Button("Открыть") { open(result) }

        if result.isInsideArchive {
            Button("Перейти к архиву") { reveal(result) }
        } else {
            Button(result.isDirectory ? "Перейти к папке" : "Перейти к файлу") { reveal(result) }
            Button("Открыть в новой вкладке") { openInNewTab(result) }
        }

        Divider()

        Button("Показать в Finder") { actions.revealInFinder(result.url) }
        if !result.isInsideArchive {
            Button("Копировать") { copy(result) }
        }
        Button("Копировать путь") { copyPath(result) }

        Divider()

        // Для записи архива свойства показываются у самого архива: у записи их
        // взять неоткуда, не распаковав её.
        Button(result.isInsideArchive ? "Свойства архива" : "Свойства") { showProperties(result) }
    }

    private func emptyState(searching: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(searching ? "Пока ничего не нашлось" : "Ничего не найдено")
                .font(.system(size: 14, weight: .medium))
            Text("Запрос «\(search.activeQuery)»")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Ход поиска: счётчики просмотренного и найденного.
    ///
    /// Счётчики, а не полоса заполнения: доля выполненного неизвестна — общее
    /// число файлов выясняется тем же обходом, который и идёт. Растущие числа
    /// честно показывают и то, что работа идёт, и с какой скоростью.
    private var progressBar: some View {
        HStack(spacing: 10) {
            ProgressView(value: search.fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .frame(width: 90)
            Text("\(Int(search.fraction * 100)) %")
                .font(.system(size: 11, weight: .medium))
                // Моноширинные цифры: иначе «9 %» и «11 %» имели бы разную
                // ширину и текст справа дёргался бы на каждом обновлении.
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
            Text(progressText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
            Button("Остановить") { search.cancel() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    /// Что именно сейчас происходит. Полоса показывает «сколько», подпись —
    /// «чего»: без неё 50 % на большой папке выглядят как остановка.
    private var progressText: String {
        let progress = search.progress
        var parts: [String] = []
        // Фаза называется по той, что идёт сейчас: показывать все три разом
        // значило бы заставить искать глазами, какая из них движется.
        if progress.totalReadableFiles > 0 {
            parts.append("читаю файлы: \(progress.readFiles) из \(progress.totalReadableFiles)")
        } else if progress.totalArchives > 0 {
            parts.append("архивы: \(progress.scannedArchives) из \(progress.totalArchives)")
        } else {
            parts.append("папки: \(progress.scannedDirectories.formatted())")
        }
        parts.append("найдено \(search.results.count)")
        return parts.joined(separator: "  ·  ")
    }

    /// Итог: сколько нашли и где искали.
    private var summaryBar: some View {
        HStack(spacing: 8) {
            Text(summaryText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    /// Итог: сколько нашли, сколько имён просмотрели и сколько файлов прочли.
    ///
    /// Число прочитанных приписывается только при включённом режиме: иначе «и
    /// прочитано 0 файлов» стояло бы в каждом обычном поиске.
    private var summaryText: String {
        let base = "Найдено \(search.results.count) · просмотрено \(search.progress.scannedFiles.formatted())"
        guard search.progress.readFiles > 0 else { return base }
        return base + " · прочитано \(search.progress.readFiles.formatted())"
    }

    /// Полоса о том, чего поиск не посмотрел.
    ///
    /// Молчать нельзя: выдача неполна, и без строки человек считал бы, что
    /// файла нет вовсе. Кнопка позволяет доискать, не набирая запрос заново.
    private var reportBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(reportText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if !search.report.skipped.isEmpty || !search.report.skippedFiles.isEmpty {
                Button("Проверить всё равно") { search.searchIncludingSkipped() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var reportText: String {
        var parts: [String] = []
        if !search.report.skipped.isEmpty {
            let names = search.report.skipped.prefix(2).map(\.url.lastPathComponent).joined(separator: ", ")
            let tail = search.report.skipped.count > 2 ? " и ещё \(search.report.skipped.count - 2)" : ""
            parts.append("не заглядывал в большие архивы: \(names)\(tail)")
        }
        // Файлы отдельной фразой, а не общим счётчиком с архивами: «3 архива и
        // 12 файлов» понятнее, чем «15 объектов», — человек по ней понимает,
        // чего именно недостаёт в выдаче.
        if !search.report.skippedFiles.isEmpty {
            let names = search.report.skippedFiles.prefix(2).map(\.url.lastPathComponent).joined(separator: ", ")
            let tail = search.report.skippedFiles.count > 2
                ? " и ещё \(search.report.skippedFiles.count - 2)"
                : ""
            parts.append("не читал содержимое больших файлов: \(names)\(tail)")
        }
        if !search.report.failed.isEmpty {
            parts.append("не удалось прочитать: \(search.report.failed.count)")
        }
        let text = parts.joined(separator: "; ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Открывает находку: файл — сразу, запись архива — через извлечение.
    private func open(_ result: SearchResult) {
        if result.isDirectory, !result.isInsideArchive {
            search.closeKeepingQuery()
            model.navigate(to: result.url)
            return
        }
        Task {
            guard let url = await search.fileToOpen(for: result) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// Переходит в папку находки и выделяет её там.
    ///
    /// Для записи архива — к самому архиву: внутрь него список файлов не ходит.
    private func reveal(_ result: SearchResult) {
        // Закрываем до навигации, а не после: смена пути сама закрывает поиск
        // через onChange в MainWindow, и запрос, восстановленный после,
        // стёрся бы этим вызовом.
        search.closeKeepingQuery()
        model.navigate(to: result.url.deletingLastPathComponent(), revealing: result.url)
    }

    private func openInNewTab(_ result: SearchResult) {
        // Папка открывается сама, файл — своей папкой: показать файл вкладкой
        // нечем. Выдача при этом остаётся, вкладка открывается фоном.
        let target = result.isDirectory ? result.url : result.url.deletingLastPathComponent()
        appState.tabs.open(target, activate: true)
    }

    private func copy(_ result: SearchResult) {
        model.copy([result.url])
    }

    private func copyPath(_ result: SearchResult) {
        // Через PasteboardService модели: свой экземпляр писал бы мимо того,
        // что читает «Вставить». Текст строит Core — UI его только передаёт.
        model.copyText(search.pathForClipboard(result))
    }

    private func showProperties(_ result: SearchResult) {
        let item = FileItem(
            url: result.url,
            name: result.url.lastPathComponent,
            isDirectory: result.isDirectory && !result.isInsideArchive
        )
        appState.pendingProperties = PropertiesBuilder.subject(for: [item])
    }

}

/// Строка находки: имя с подсветкой совпадения и путь под ним.
private struct SearchResultRow: View {
    let result: SearchResult
    let root: URL?

    var body: some View {
        HStack(spacing: 8) {
            // Иконка по имени находки, а не по URL: у записи архива URL ведёт
            // на сам архив, и все записи получили бы иконку архива.
            Image(nsImage: IconCache.icon(for: FileItem(
                url: URL(fileURLWithPath: "/\(result.name)"),
                name: result.name,
                isDirectory: result.isDirectory
            )))
            .resizable()
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                highlightedName
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let location {
                    HStack(spacing: 3) {
                        if result.isInsideArchive {
                            // Значок архива отличает находку внутри архива от
                            // обычной папки: путь со стрелкой сам по себе легко
                            // прочитать как вложенную папку.
                            Image(systemName: "archivebox")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Text(location)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                // Фрагмент содержимого — третьей строкой. Ради него поиск по
                // содержимому и затевался: без контекста «нашлось в 40 файлах»
                // бесполезно, пришлось бы открывать каждый.
                if let snippet = result.snippet {
                    highlighted(snippet)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var location: String? {
        guard let root else { return nil }
        let text = result.location(relativeTo: root)
        return text.isEmpty ? nil : text
    }

    /// Имя с выделенными буквами запроса.
    ///
    /// Подсветка объясняет, почему файл найден: при нечётком совпадении связь
    /// имени с запросом иначе не видна вовсе.
    private var highlightedName: Text {
        highlight(result.name, at: result.matchedIndices, base: nil)
    }

    /// Фрагмент содержимого с выделенным совпадением.
    private func highlighted(_ snippet: ContentSnippet) -> Text {
        highlight(snippet.text, at: snippet.matchedIndices, base: .secondary)
    }

    /// Строка, у которой часть символов выделена цветом и жирностью.
    ///
    /// Посимвольная склейка `Text`, а не `AttributedString`: подсветка идёт по
    /// индексам символов, а перевод их в диапазоны `AttributedString` потребовал
    /// бы возни с `Character` против `UTF-8`-смещений ради того же результата.
    private func highlight(_ string: String, at indices: [Int], base: Color?) -> Text {
        let matched = Set(indices)
        return Array(string).enumerated().reduce(Text("")) { text, pair in
            let character = Text(String(pair.element))
            if matched.contains(pair.offset) {
                return text + character.foregroundColor(.accentColor).bold()
            }
            return text + (base.map { character.foregroundColor($0) } ?? character)
        }
    }
}
