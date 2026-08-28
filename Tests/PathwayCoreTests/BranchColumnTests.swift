import Foundation
import Testing

@testable import PathwayCore

@Suite("Колонка «Ветка» в списке файлов")
@MainActor
struct BranchColumnTests {

    private func makeRepo(in dir: URL, name: String, branch: String) throws -> URL {
        let repo = dir.appendingPathComponent(name)
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/\(branch)\n"
            .write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return repo
    }

    @Test("второй проход читает ветку папки-репозитория")
    func metadataPassReadsBranch() throws {
        try withTempDir { dir in
            _ = try makeRepo(in: dir, name: "Проект", branch: "main")
            let loader = DirectoryLoader()

            let names = try loader.loadNames(directory: dir)
            let detailed = loader.loadMetadata(for: names)

            let project = try #require(detailed.first { $0.name == "Проект" })
            #expect(project.branch == "main")
        }
    }

    @Test("первый проход ветку не читает: диск он не трогает")
    func namesPassSkipsBranch() throws {
        try withTempDir { dir in
            _ = try makeRepo(in: dir, name: "Проект", branch: "main")

            let names = try DirectoryLoader().loadNames(directory: dir)

            let project = try #require(names.first { $0.name == "Проект" })
            #expect(project.branch == nil)
        }
    }

    @Test("обычная папка ветку не получает")
    func plainFolderHasNoBranch() throws {
        try withTempDir { dir in
            let plain = dir.appendingPathComponent("Обычная")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            let loader = DirectoryLoader()

            let detailed = loader.loadMetadata(for: try loader.loadNames(directory: dir))

            let folder = try #require(detailed.first { $0.name == "Обычная" })
            #expect(folder.branch == nil)
        }
    }

    @Test("файлы ветку не получают никогда")
    func filesNeverHaveBranch() throws {
        try withTempDir { dir in
            try "текст".write(to: dir.appendingPathComponent("файл.txt"), atomically: true, encoding: .utf8)
            let loader = DirectoryLoader()

            let detailed = loader.loadMetadata(for: try loader.loadNames(directory: dir))

            let file = try #require(detailed.first { $0.name == "файл.txt" })
            #expect(file.branch == nil)
        }
    }

    @Test("на сетевом томе ветка не читается: проверка .git там слишком дорога")
    func skipsBranchOnNetworkVolume() throws {
        try withTempDir { dir in
            _ = try makeRepo(in: dir, name: "Проект", branch: "main")
            let loader = DirectoryLoader()

            // Холодная проверка отсутствия .git на SMB стоит 13–21 мс на папку
            // против 0.02 мс локально, а репозитории на шарах практически не
            // встречаются — платить за них полным обходом нельзя.
            let detailed = loader.loadMetadata(for: try loader.loadNames(directory: dir), isLocalVolume: false)

            let project = try #require(detailed.first { $0.name == "Проект" })
            #expect(project.branch == nil)
            // Размер и дата при этом читаются как обычно: дорога именно
            // проверка несуществующего .git, а не stat самой папки.
            #expect(project.metadataLoaded)
        }
    }

    // MARK: - Сортировка

    private func items(_ pairs: [(String, String?)]) -> [FileItem] {
        pairs.map { name, branch in
            FileItem(
                url: URL(fileURLWithPath: "/tmp/\(name)"),
                name: name,
                isDirectory: true,
                branch: branch
            )
        }
    }

    @Test("сортировка по ветке кладёт папки без ветки вниз при возрастании")
    func emptyBranchesLastAscending() {
        let sorted = BrowserModel.sorted(
            items([("б", nil), ("а", "main"), ("в", "develop")]),
            by: SortSettings(key: "branch", ascending: true)
        )
        #expect(sorted.map(\.name) == ["в", "а", "б"])
    }

    @Test("сортировка по ветке кладёт папки без ветки вниз и при убывании")
    func emptyBranchesLastDescending() {
        let sorted = BrowserModel.sorted(
            items([("б", nil), ("а", "main"), ("в", "develop")]),
            by: SortSettings(key: "branch", ascending: false)
        )
        #expect(sorted.map(\.name) == ["а", "в", "б"])
    }

    @Test("при равных ветках порядок задаёт имя, а не выдача readdir")
    func equalBranchesSortByName() {
        let sorted = BrowserModel.sorted(
            items([("в", "main"), ("а", "main"), ("б", "main")]),
            by: SortSettings(key: "branch", ascending: true)
        )
        // Половина проектов стоит на main: без разрешения ничьей они шли бы
        // в случайном на глаз порядке, и группировка теряла бы смысл.
        #expect(sorted.map(\.name) == ["а", "б", "в"])
    }

    @Test("тайбрейк по имени не переворачивается вместе с направлением")
    func nameTiebreakStaysAscending() {
        let sorted = BrowserModel.sorted(
            items([("в", "main"), ("а", "main"), ("б", "main")]),
            by: SortSettings(key: "branch", ascending: false)
        )
        // Ветки равны, переворачивать нечего: имена остаются по возрастанию,
        // иначе список прыгал бы при клике по заголовку без видимой причины.
        #expect(sorted.map(\.name) == ["а", "б", "в"])
    }

    @Test("текст колонки — имя ветки, а для папки без неё пусто, а не прочерк")
    func columnTextIsBranchOrEmpty() {
        let model = BrowserModel(path: URL(fileURLWithPath: "/tmp"))
        let list = items([("а", "main"), ("б", nil)])
        #expect(model.text(for: list[0], column: "branch") == "main")
        // Пусто, а не «—»: прочерк в колонке ветки читался бы как «ветка есть,
        // но неизвестна», тогда как папка просто не репозиторий.
        #expect(model.text(for: list[1], column: "branch") == "")
    }
}

@Suite("Обновление ветки после смены снаружи")
@MainActor
struct BranchRefreshTests {

    @Test("возврат в приложение подхватывает ветку, переключённую в терминале")
    func returningToAppPicksUpNewBranch() async throws {
        try await withTempDirAsync { dir in
            let repo = dir.appendingPathComponent("Проект")
            let git = repo.appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            let head = git.appendingPathComponent("HEAD")
            try "ref: refs/heads/main\n".write(to: head, atomically: true, encoding: .utf8)

            let model = BrowserModel(path: dir)
            model.reloadAsync()
            await model.waitForLoad()
            #expect(model.items.first?.branch == "main")

            // Терминал переключил ветку: .git/HEAD лежит уровнем глубже, чем
            // следит наблюдатель, и события об этом не приходит.
            try "ref: refs/heads/feature/новая\n".write(to: head, atomically: true, encoding: .utf8)

            model.refreshAfterReturn()
            await model.waitForRefresh()
            await model.waitForMetadata()

            #expect(model.items.first?.branch == "feature/новая")
        }
    }
}
