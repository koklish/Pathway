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
}
