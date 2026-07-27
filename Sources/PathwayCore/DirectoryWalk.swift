import Foundation

/// Рекурсивный обход каталога для поиска: имена файлов и список архивов.
///
/// Отдельно от `DirectoryLoader`, потому что задачи разные: тот читает **одну**
/// папку для показа в списке (с метаданными, сортировкой и локализованными
/// именами системных папок), а этому нужен обход **вглубь** без всего этого.
///
/// Общее — приём: `opendir`/`readdir` с типом из `d_type`, ни одного обращения
/// к диску за атрибутами. На сетевом томе `URL` пошёл бы выяснять тип файла
/// отдельным запросом к серверу на каждый объект: замер в `DirectoryLoader`
/// дал 4824 мс против 0.7 мс на 510 подпапках.
public enum DirectoryWalk {

    public struct Entry: Sendable {
        public let url: URL
        public let name: String
        public let isDirectory: Bool
    }

    public struct Result: Sendable {
        public var files: [Entry] = []
        public var archives: [URL] = []
        /// Папок, ещё не обойдённых, на момент выдачи этой порции.
        ///
        /// Знаменатель для доли выполненного: общего числа файлов заранее нет,
        /// но «обойдено / (обойдено + осталось)» — настоящая оценка, а не
        /// выдумка. Она не монотонна (очередь пополняется, когда находятся
        /// подпапки), зато сходится к единице.
        public var queuedDirectories = 0
    }

    /// Максимальная глубина. Не для скорости, а против петель: символические
    /// ссылки на родителя дали бы бесконечный обход. По ссылкам обход не
    /// ходит, но каталог может оказаться примонтированным сам в себя.
    private static let maxDepth = 24

    /// Каталоги, в которые не заходим никогда.
    ///
    /// Содержимое бандлов — это внутренности приложений и документов Pages, а
    /// не файлы пользователя; выдача из них состояла бы из чужих ресурсов.
    private static let skippedExtensions: Set<String> = [
        "app", "framework", "bundle", "photoslibrary", "fcpbundle", "pages", "numbers", "key",
    ]

    /// Обходит дерево от `root`, разделяя обычные файлы и архивы.
    ///
    /// Скрытые файлы пропускаются: поиск по видимому — то, чего ждёт человек, а
    /// внутри `.git` и `node_modules` лежат десятки тысяч имён, которые
    /// утопили бы выдачу.
    public static func collect(root: URL, isCancelled: @Sendable () -> Bool = { false }) -> Result {
        var result = Result()
        walk(root: root, isCancelled: isCancelled) { batch in
            result.files.append(contentsOf: batch.files)
            result.archives.append(contentsOf: batch.archives)
        }
        return result
    }

    /// Тот же обход, но отдающий содержимое каждой папки сразу, как прочитал.
    ///
    /// Нужен потому, что `collect` возвращает результат лишь в конце: на
    /// сетевом томе с тысячами папок обход идёт секунды, и всё это время
    /// поиску нечего показать. Здесь первая находка появляется после первой
    /// прочитанной папки, а не после последней.
    ///
    /// Порция — ровно одна папка, а не накопленный буфер: папка и так
    /// естественная единица (один `opendir`), а укрупнение порций вернуло бы
    /// задержку, ради устранения которой это и сделано.
    public static func walk(
        root: URL,
        isCancelled: @Sendable () -> Bool = { false },
        onBatch: (Result) -> Void
    ) {
        var queue: [(url: URL, depth: Int)] = [(root, 0)]

        while !queue.isEmpty {
            if isCancelled() { return }
            let (directory, depth) = queue.removeLast()
            guard let handle = opendir(directory.path) else { continue }
            defer { closedir(handle) }

            var result = Result()

            // Префикс готовится один раз: конкатенация строк вместо построения
            // URL от URL — то же, что в DirectoryLoader.
            let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"

            while let entry = readdir(handle) {
                var raw = entry.pointee.d_name
                let name = withUnsafePointer(to: &raw) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                guard name != ".", name != "..", !name.hasPrefix(".") else { continue }

                let type = entry.pointee.d_type
                // Символические ссылки не разыменовываем: ссылка на родителя
                // увела бы обход по кругу, а на сетевой том — в долгое ожидание.
                guard type != DT_LNK else { continue }

                let isDirectory = type == DT_DIR
                let url = URL(fileURLWithPath: base + name, isDirectory: isDirectory)

                if isDirectory {
                    guard depth < maxDepth else { continue }
                    guard !skippedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    queue.append((url, depth + 1))
                    result.files.append(Entry(url: url, name: name, isDirectory: true))
                } else {
                    result.files.append(Entry(url: url, name: name, isDirectory: false))
                    if ArchiveService.isArchive(url) { result.archives.append(url) }
                }
            }

            result.queuedDirectories = queue.count
            onBatch(result)
        }
    }
}
