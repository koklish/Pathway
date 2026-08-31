import Foundation
import Testing

@testable import PathwayCore

/// Проверки против настоящего git на настоящем репозитории.
///
/// Остальные тесты git работают на фейке и проверяют, что мы посылаем нужные
/// аргументы. Здесь проверяется противоположное — что git на эти аргументы
/// отвечает тем, что мы умеем разбирать: сменившийся формат porcelain или
/// опечатка во флаге на фейке остались бы незамеченными.
@Suite("Настоящий git", .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/git")))
struct GitCLIIntegrationTests {

    /// Репозиторий с одним коммитом. Личность автора задаётся флагами: на
    /// машине без user.email коммит иначе не создастся.
    private func makeRepository(at dir: URL) async throws {
        let git = GitCLI()
        _ = try await git.run(["init", "-q", "-b", "main"], in: dir)
        _ = try await git.run(["config", "user.email", "тест@pathway"], in: dir)
        _ = try await git.run(["config", "user.name", "Тест"], in: dir)
        try "первый".write(to: dir.appendingPathComponent("файл.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: dir)
        _ = try await git.run(["commit", "-q", "-m", "Первый"], in: dir)
    }

    @Test("состояние чистого репозитория читается через настоящий git")
    func readsCleanRepository() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)

            let status = try await GitService().status(at: dir)

            #expect(status.branch == "main")
            #expect(status.isDirty == false)
            // Upstream нет — счётчиков быть не должно, а не нулей.
            #expect(status.ahead == nil)
            #expect(status.behind == nil)
        }
    }

    @Test("изменённый и неотслеживаемый файлы делают дерево грязным")
    func detectsDirtyTree() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)

            try "второй".write(to: dir.appendingPathComponent("файл.txt"), atomically: true, encoding: .utf8)
            #expect(try await GitService().status(at: dir).isDirty)

            _ = try await GitCLI().run(["checkout", "--", "."], in: dir)
            #expect(try await GitService().status(at: dir).isDirty == false)

            try "новый".write(to: dir.appendingPathComponent("новый.txt"), atomically: true, encoding: .utf8)
            #expect(try await GitService().status(at: dir).isDirty)
        }
    }

    @Test("файл с переносом строки в имени не ломает разбор")
    func handlesNewlineInFileName() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)
            // Без -z git закавычивает такое имя, и перенос в разбор не попадает.
            // С -z, как предлагала спека, строка разъехалась бы по split("\n").
            try "текст".write(to: dir.appendingPathComponent("плохое\nимя.txt"), atomically: true, encoding: .utf8)

            let status = try await GitService().status(at: dir)

            #expect(status.branch == "main")
            #expect(status.isDirty)
        }
    }

    @Test("detached HEAD читается коротким хешем и из HEAD, и из status")
    func readsDetachedHead() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)
            let head = try await GitCLI().run(["rev-parse", "HEAD"], in: dir)
            let sha = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await GitCLI().run(["checkout", "-q", sha], in: dir)

            let expected = String(sha.prefix(7))
            #expect(try await GitService().status(at: dir).branch == expected)
            #expect(GitRepository.branch(at: dir) == expected)
        }
    }

    @Test("ветка из .git/HEAD совпадает с тем, что показывает git")
    func fileReadMatchesGit() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)
            _ = try await GitCLI().run(["checkout", "-q", "-b", "feature/ветка"], in: dir)

            // Смысл всей оптимизации: чтение файла обязано давать то же, что и
            // запуск процесса, иначе колонка врала бы.
            #expect(GitRepository.branch(at: dir) == "feature/ветка")
            #expect(try await GitService().status(at: dir).branch == "feature/ветка")
        }
    }

    @Test("клонирование создаёт рабочую копию с той же историей")
    func clonesRepository() async throws {
        try await withTempDirAsync { dir in
            let source = dir.appendingPathComponent("Источник")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try await makeRepository(at: source)

            let destination = dir.appendingPathComponent("Куда")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            try await GitService().clone(from: source.path, into: destination, name: "Копия")

            let copy = destination.appendingPathComponent("Копия")
            #expect(GitRepository.isRepository(copy))
            #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("файл.txt").path))
        }
    }

    @Test("ошибка настоящего git доходит текстом, а не молчанием")
    func reportsRealError() async throws {
        try await withTempDirAsync { dir in
            // Не репозиторий вовсе: git обязан пожаловаться, а мы — показать.
            await #expect(throws: GitError.self) {
                try await GitService().fetch(at: dir)
            }
        }
    }

    @Test("отсутствие git объясняет, что установить, а не жалуется на папку")
    func missingToolExplainsInstallation() async throws {
        try await withTempDirAsync { dir in
            // Системная NSFileNoSuchFileError уехала бы в общий describe и
            // превратилась в «Папка больше не существует» — про папку, с
            // которой всё в порядке.
            let missing = GitCLI(tool: URL(fileURLWithPath: "/usr/bin/нет-такой-программы"))
            do {
                _ = try await missing.run(["status"], in: dir)
                Issue.record("ожидалась ошибка")
            } catch let error as GitError {
                #expect(error.message.contains("xcode-select --install"))
            }
        }
    }

    @Test("отмена операции не оставляет процесс работать")
    func cancellationTerminatesProcess() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)

            let task = Task {
                // Заведомо недостижимый адрес: git будет ждать сеть.
                try await GitCLI().run(
                    ["clone", "https://192.0.2.1/недостижимо.git"], in: dir)
            }
            try await Task.sleep(for: .milliseconds(150))
            task.cancel()

            // Отмена обязана дать CancellationError, а не ошибку от ненулевого
            // кода убитого процесса.
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    /// Сервер и клиент: голый репозиторий и два рабочих дерева при нём.
    /// Нужны, чтобы проверить fetch и pull по-настоящему — с обменом.
    private func makeServerAndClient(at dir: URL) async throws -> (server: URL, author: URL, client: URL) {
        let git = GitCLI()
        let server = dir.appendingPathComponent("server.git")
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        _ = try await git.run(["init", "-q", "--bare", "-b", "main"], in: server)

        let author = dir.appendingPathComponent("author")
        _ = try await git.run(["clone", "-q", server.path, author.path], in: dir)
        _ = try await git.run(["config", "user.email", "тест@pathway"], in: author)
        _ = try await git.run(["config", "user.name", "Тест"], in: author)
        try "первый".write(to: author.appendingPathComponent("файл.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: author)
        _ = try await git.run(["commit", "-q", "-m", "Первый"], in: author)
        _ = try await git.run(["push", "-q", "-u", "origin", "main"], in: author)

        let client = dir.appendingPathComponent("client")
        _ = try await git.run(["clone", "-q", server.path, client.path], in: dir)
        return (server, author, client)
    }

    /// Добавляет коммит в авторское дерево и отправляет его на сервер.
    private func publish(_ text: String, from author: URL) async throws {
        let git = GitCLI()
        let file = author.appendingPathComponent("файл.txt")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try (existing + "\n" + text).write(to: file, atomically: true, encoding: .utf8)
        _ = try await git.run(["commit", "-qam", text], in: author)
        _ = try await git.run(["push", "-q"], in: author)
    }

    @Test("после fetch отставание видно, даже когда refs обновил кто-то раньше")
    func fetchSeesBehindAfterSomeoneElseFetched() async throws {
        try await withTempDirAsync { dir in
            let repos = try await makeServerAndClient(at: dir)
            let service = GitService()
            try await publish("второй", from: repos.author)
            try await publish("третий", from: repos.author)

            // Refs обновляет посторонний — среда разработки или терминал.
            try await service.fetch(at: repos.client)
            // Теперь наш Fetch: прироста он не даёт, refs уже свежие.
            try await service.fetch(at: repos.client)
            let after = try await service.status(at: repos.client)

            // Ровно случай, из-за которого тост говорил «Нового нет» перед
            // pull, приносившим два коммита.
            #expect(after.behind == 2)
        }
    }

    @Test("pull приносит коммиты, о которых счётчик до операции не знал")
    func pullBringsCommitsStaleCounterMissed() async throws {
        try await withTempDirAsync { dir in
            let repos = try await makeServerAndClient(at: dir)
            let service = GitService()
            try await publish("второй", from: repos.author)
            try await publish("третий", from: repos.author)

            // Клиент о чужих коммитах ещё не слышал: fetch никто не делал.
            let before = try await service.status(at: repos.client)
            #expect(before.behind == 0)

            let oldHead = try await service.head(at: repos.client)
            try await service.pull(at: repos.client)
            let newHead = try await service.head(at: repos.client)

            // Счётчик до операции показал ноль, а пришло два: pull сам
            // начинается с fetch. Отсюда подсчёт по HEAD, а не по счётчику.
            let arrived = try await service.commitCount(from: oldHead!, to: newHead!, at: repos.client)
            #expect(arrived == 2)
        }
    }

    @Test("отправленное считается по счётчику «впереди»: сеть для него не нужна")
    func pushCountsFromLocalAheadCounter() async throws {
        try await withTempDirAsync { dir in
            let repos = try await makeServerAndClient(at: dir)
            let git = GitCLI()
            _ = try await git.run(["config", "user.email", "тест@pathway"], in: repos.client)
            _ = try await git.run(["config", "user.name", "Тест"], in: repos.client)
            try "моё".write(to: repos.client.appendingPathComponent("моё.txt"), atomically: true, encoding: .utf8)
            _ = try await git.run(["add", "."], in: repos.client)
            _ = try await git.run(["commit", "-q", "-m", "Моё"], in: repos.client)

            let service = GitService()
            let before = try await service.status(at: repos.client)

            // Локальные коммиты git знает без обращения к серверу, и устареть
            // этот счётчик не может — в отличие от «позади».
            #expect(before.ahead == 1)
        }
    }

    // MARK: - История и коммит

    @Test("история настоящего репозитория разбирается в коммиты")
    func readsRealLog() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)

            let commits = try await GitService().log(at: dir, limit: 10)

            #expect(commits.count == 1)
            #expect(commits[0].subject == "Первый")
            #expect(commits[0].author == "Тест")
            // HEAD указывает на main — панель по этой ссылке рисует «вы здесь».
            #expect(commits[0].refs.contains(CommitRef(name: "main", kind: .head)))
        }
    }

    @Test("слияние в настоящем репозитории даёт коммит с двумя родителями")
    func readsRealMerge() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)
            let git = GitCLI()

            _ = try await git.run(["switch", "-q", "-c", "ветка"], in: dir)
            try "вбок".write(to: dir.appendingPathComponent("вбок.txt"), atomically: true, encoding: .utf8)
            _ = try await git.run(["add", "."], in: dir)
            _ = try await git.run(["commit", "-q", "-m", "Вбок"], in: dir)
            _ = try await git.run(["switch", "-q", "main"], in: dir)
            try "прямо".write(to: dir.appendingPathComponent("прямо.txt"), atomically: true, encoding: .utf8)
            _ = try await git.run(["add", "."], in: dir)
            _ = try await git.run(["commit", "-q", "-m", "Прямо"], in: dir)
            _ = try await git.run(["merge", "--no-ff", "-m", "Слияние", "ветка"], in: dir)

            let commits = try await GitService().log(at: dir, limit: 10)
            let rows = GitGraph.build(commits)

            #expect(commits[0].isMerge)
            #expect(commits[0].parents.count == 2)
            // Из строки слияния выходят две линии: без второй ветка «ветка»
            // висела бы в графе оборванной.
            #expect(rows[0].links.count == 2)
            #expect(rows.map(\.width).max() == 2)
        }
    }

    @Test("изменения настоящего репозитория различают индекс и рабочее дерево")
    func readsRealChanges() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)
            let service = GitService()

            try "правка".write(to: dir.appendingPathComponent("файл.txt"), atomically: true, encoding: .utf8)
            try "новый".write(to: dir.appendingPathComponent("новый.txt"), atomically: true, encoding: .utf8)

            let before = try await service.changes(at: dir)
            #expect(before.count == 2)
            #expect(before.allSatisfy { !$0.isStaged })
            #expect(before.contains { $0.status == .untracked })

            try await service.stage(["файл.txt"], at: dir)
            let after = try await service.changes(at: dir)

            // Индекс и галочки — одно состояние: файл, добавленный git add,
            // обязан прийти сюда отмеченным.
            #expect(after.first { $0.path == "файл.txt" }?.isStaged == true)
            #expect(after.first { $0.path == "новый.txt" }?.isStaged == false)
        }
    }

    @Test("коммит через сервис появляется в истории")
    func commitAppearsInLog() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)
            let service = GitService()

            try "правка".write(to: dir.appendingPathComponent("файл.txt"), atomically: true, encoding: .utf8)
            try await service.stage(["файл.txt"], at: dir)
            try await service.commit(message: "Вторая правка", at: dir)

            let commits = try await service.log(at: dir, limit: 10)

            #expect(commits.map(\.subject) == ["Вторая правка", "Первый"])
            #expect(try await service.changes(at: dir).isEmpty)
        }
    }

    @Test("файлы коммита читаются, включая самый первый в истории")
    func readsFilesOfCommits() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)
            let service = GitService()

            let commits = try await service.log(at: dir, limit: 10)
            // Именно первый коммит: у него нет родителя, и ошибка во флагах
            // git show дала бы здесь пустой список вместо файлов.
            let files = try await service.files(of: commits[0].hash, at: dir)

            #expect(files.map(\.path) == ["файл.txt"])
            #expect(files[0].status == .added)
        }
    }

    @Test("откат возвращает изменённый файл и удаляет неотслеживаемый")
    func discardRestoresAndDeletes() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)
            let service = GitService()
            let tracked = dir.appendingPathComponent("файл.txt")
            let untracked = dir.appendingPathComponent("лишний.txt")

            try "испорчено".write(to: tracked, atomically: true, encoding: .utf8)
            try "мусор".write(to: untracked, atomically: true, encoding: .utf8)

            try await service.discard(["файл.txt"], untracked: ["лишний.txt"], at: dir)

            #expect(try String(contentsOf: tracked, encoding: .utf8) == "первый")
            #expect(!FileManager.default.fileExists(atPath: untracked.path))
            #expect(try await service.changes(at: dir).isEmpty)
        }
    }

    @Test("русское имя файла в изменениях читается, а не приходит escape-последовательностями")
    func readsCyrillicPathInChanges() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)

            // git закавычивает всё вне ASCII и пишет байты в \nnn. Без
            // раскавычивания панель показывала бы «\321\204» вместо имени —
            // а в этом проекте русские имена обычны.
            let folder = dir.appendingPathComponent("моя папка")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "текст".write(
                to: folder.appendingPathComponent("заметка.txt"),
                atomically: true, encoding: .utf8
            )

            let changes = try await GitService().changes(at: dir)

            #expect(changes.map(\.path) == ["моя папка/заметка.txt"])
        }
    }

    @Test("новая папка приходит списком файлов, а не одной записью «папка/»")
    func listsFilesInsideUntrackedFolder() async throws {
        try await withTempDirAsync { dir in
            try await makeRepository(at: dir)

            // Без -uall git сворачивает всю новую папку в одну строку «новая/»,
            // и галочка на ней означала бы «всё внутри» — а панель отмечает
            // файлы поштучно, и снять один из них было бы нечем.
            let nested = dir.appendingPathComponent("новая/вложенная")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try "a".write(to: dir.appendingPathComponent("новая/а.txt"), atomically: true, encoding: .utf8)
            try "b".write(to: nested.appendingPathComponent("б.txt"), atomically: true, encoding: .utf8)

            let changes = try await GitService().changes(at: dir)

            #expect(changes.map(\.path).sorted() == ["новая/а.txt", "новая/вложенная/б.txt"])
        }
    }
}
