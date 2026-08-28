import Foundation
import Testing

@testable import PathwayCore

@Suite("Определение репозитория и текущей ветки")
struct GitRepositoryTests {

    /// Создаёт внутри dir папку-репозиторий с заданным содержимым .git/HEAD.
    private func makeRepo(in dir: URL, name: String, head: String) throws -> URL {
        let repo = dir.appendingPathComponent(name)
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try head.write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return repo
    }

    @Test("читает имя ветки из .git/HEAD")
    func readsBranchName() throws {
        try withTempDir { dir in
            let repo = try makeRepo(in: dir, name: "Проект", head: "ref: refs/heads/main\n")
            #expect(GitRepository.branch(at: repo) == "main")
        }
    }

    @Test("сохраняет косые черты в имени ветки")
    func keepsSlashesInBranchName() throws {
        try withTempDir { dir in
            let repo = try makeRepo(in: dir, name: "Проект", head: "ref: refs/heads/feature/git-column\n")
            #expect(GitRepository.branch(at: repo) == "feature/git-column")
        }
    }

    @Test("при detached HEAD отдаёт короткий хеш, а не полный SHA")
    func shortensDetachedHead() throws {
        try withTempDir { dir in
            let sha = "9f2c1a4b8d3e5f60718293a4b5c6d7e8f9012345"
            let repo = try makeRepo(in: dir, name: "Проект", head: sha + "\n")
            #expect(GitRepository.branch(at: repo) == "9f2c1a4")
        }
    }

    @Test("понимает .git как файл с gitdir: — worktree и подмодуль")
    func followsGitdirFile() throws {
        try withTempDir { dir in
            // Настоящая служебная папка лежит в стороне, как у подмодулей.
            let real = dir.appendingPathComponent("modules/Подмодуль")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try "ref: refs/heads/develop\n"
                .write(to: real.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

            let repo = dir.appendingPathComponent("Проект")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try "gitdir: \(real.path)\n"
                .write(to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

            #expect(GitRepository.branch(at: repo) == "develop")
        }
    }

    @Test("относительный gitdir считается от самой папки репозитория")
    func resolvesRelativeGitdir() throws {
        try withTempDir { dir in
            let real = dir.appendingPathComponent("общий/служебная")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try "ref: refs/heads/main\n"
                .write(to: real.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

            let repo = dir.appendingPathComponent("Проект")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try "gitdir: ../общий/служебная\n"
                .write(to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

            #expect(GitRepository.branch(at: repo) == "main")
        }
    }

    @Test("битый HEAD даёт nil, а не ошибку")
    func brokenHeadGivesNil() throws {
        try withTempDir { dir in
            let repo = try makeRepo(in: dir, name: "Проект", head: "мусор\n")
            #expect(GitRepository.branch(at: repo) == nil)
        }
    }

    @Test("папка без .git репозиторием не является")
    func plainFolderIsNotRepository() throws {
        try withTempDir { dir in
            let plain = dir.appendingPathComponent("Обычная")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            #expect(GitRepository.branch(at: plain) == nil)
            #expect(GitRepository.isRepository(plain) == false)
        }
    }

    @Test("папка с .git является репозиторием")
    func folderWithGitIsRepository() throws {
        try withTempDir { dir in
            let repo = try makeRepo(in: dir, name: "Проект", head: "ref: refs/heads/main\n")
            #expect(GitRepository.isRepository(repo))
        }
    }

    @Test("поиск корня находит репозиторий из вложенной папки")
    func findsRootFromNestedFolder() throws {
        try withTempDir { dir in
            let repo = try makeRepo(in: dir, name: "Проект", head: "ref: refs/heads/main\n")
            let nested = repo.appendingPathComponent("Sources/PathwayCore")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

            #expect(GitRepository.root(containing: nested)?.path == repo.path)
        }
    }

    @Test("поиск корня возвращает саму папку, если она и есть репозиторий")
    func rootOfRepositoryIsItself() throws {
        try withTempDir { dir in
            let repo = try makeRepo(in: dir, name: "Проект", head: "ref: refs/heads/main\n")
            #expect(GitRepository.root(containing: repo)?.path == repo.path)
        }
    }

    @Test("вне репозитория поиск корня даёт nil, а не корень тома")
    func noRootOutsideRepository() throws {
        try withTempDir { dir in
            let plain = dir.appendingPathComponent("Обычная")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            #expect(GitRepository.root(containing: plain) == nil)
        }
    }

    @Test("короткий хеш отличается от имени ветки")
    func detectsDetachedHead() {
        #expect(GitRepository.isDetached("a3f91c2"))
        #expect(GitRepository.isDetached("main") == false)
        #expect(GitRepository.isDetached("feature/SDLC/35") == false)
        // Слишком длинное для короткого хеша — значит имя.
        #expect(GitRepository.isDetached("abcdef12") == false)
    }

    @Test("имя ветки из семи hex-символов принимается за хеш — известная плата")
    func hexLikeBranchNameLooksDetached() {
        // git такое имя создать позволяет. Различить их можно было бы только
        // чтением .git/refs, то есть ещё одним обращением к диску на каждую
        // строку списка; цена ошибки — другой значок в чипе.
        #expect(GitRepository.isDetached("abcdef1"))
    }
}
