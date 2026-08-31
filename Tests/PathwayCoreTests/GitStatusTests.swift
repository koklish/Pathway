import Foundation
import Testing

@testable import PathwayCore

@Suite("Разбор состояния репозитория")
struct GitStatusTests {

    @Test("разбирает ветку, upstream и счётчики впереди и позади")
    func parsesBranchAndCounters() {
        let output = """
        # branch.oid 88675656a7fcd1786816432b95f461836dc842ca
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +3 -2
        """
        let status = GitStatus.parse(output)

        #expect(status.branch == "main")
        #expect(status.ahead == 3)
        #expect(status.behind == 2)
    }

    @Test("ветка без upstream даёт отсутствие счётчиков, а не нули")
    func missingUpstreamHasNoCounters() {
        let output = """
        # branch.oid 739d1ee30050aac689fb4406d3238feae36f8c5e
        # branch.head main
        """
        let status = GitStatus.parse(output)

        #expect(status.branch == "main")
        // Именно nil: «0 впереди, 0 позади» означало бы, что мы синхронны с
        // сервером, тогда как сравнивать не с чем вовсе.
        #expect(status.ahead == nil)
        #expect(status.behind == nil)
    }

    @Test("отличает чистое дерево от изменённого")
    func detectsDirtyTree() {
        let clean = """
        # branch.head main
        # branch.ab +0 -0
        """
        #expect(GitStatus.parse(clean).isDirty == false)

        let dirty = """
        # branch.head main
        # branch.ab +0 -0
        1 .M N... 100644 100644 100644 abc def Sources/PathwayCore/BrowserModel.swift
        """
        #expect(GitStatus.parse(dirty).isDirty)
    }

    @Test("неотслеживаемый файл делает дерево изменённым")
    func untrackedFileMakesDirty() {
        let output = """
        # branch.head main
        ? docs/новая-спека.md
        """
        #expect(GitStatus.parse(output).isDirty)
    }

    @Test("считает изменённые файлы, а не только факт изменений")
    func countsChangedFiles() {
        let output = """
        # branch.head main
        1 .M N... 100644 100644 100644 abc def Sources/PathwayCore/BrowserModel.swift
        1 M. N... 100644 100644 100644 abc def Sources/Pathway/BranchChip.swift
        ? docs/новая-спека.md
        """
        // Число, а не признак: чип показывает «сколько», и вывести это из
        // булева isDirty нельзя.
        #expect(GitStatus.parse(output).changedFiles == 3)
    }

    @Test("чистое дерево даёт ноль изменённых файлов")
    func cleanTreeHasNoChangedFiles() {
        let output = """
        # branch.head main
        # branch.ab +0 -0
        """
        #expect(GitStatus.parse(output).changedFiles == 0)
    }

    @Test("переименование считается одним файлом, а не двумя")
    func renameCountsAsOneFile() {
        // Строка «2» несёт оба пути разом, разделённые табуляцией: считай по
        // путям — переименование удваивало бы счётчик на ровном месте.
        let output = """
        # branch.head main
        2 R. N... 100644 100644 100644 abc def R100 новое\tстарое
        """
        #expect(GitStatus.parse(output).changedFiles == 1)
    }

    @Test("служебные строки заголовка в счётчик не попадают")
    func headerLinesAreNotCounted() {
        // Заголовки начинаются с «#», а «1», «2», «u», «?» — коды состояний.
        // Сравнение по первому символу без отсечения «#» посчитало бы их тоже.
        let output = """
        # branch.oid 1234567
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +1 -0
        """
        #expect(GitStatus.parse(output).changedFiles == 0)
    }

    @Test("конфликт слияния делает дерево изменённым")
    func conflictMakesDirty() {
        let output = """
        # branch.head main
        u UU N... 100644 100644 100644 100644 a b c d Package.swift
        """
        #expect(GitStatus.parse(output).isDirty)
    }

    @Test("при detached HEAD ветка — короткий хеш, а не слово detached")
    func detachedHeadShowsShortHash() {
        let output = """
        # branch.oid 9f2c1a4b8d3e5f60718293a4b5c6d7e8f9012345
        # branch.head (detached)
        """
        let status = GitStatus.parse(output)

        // «(detached)» — служебное слово git, в интерфейсе от него никакого
        // толку: человеку нужен коммит, на котором он стоит.
        #expect(status.branch == "9f2c1a4")
    }

    @Test("пустой вывод не роняет разбор")
    func emptyOutputIsSafe() {
        let status = GitStatus.parse("")

        #expect(status.branch == nil)
        #expect(status.ahead == nil)
        #expect(status.isDirty == false)
    }

    @Test("без upstream ahead равен nil, а не нулю")
    func missingUpstreamGivesNilCounters() {
        // Строки branch.ab в выводе нет вовсе, когда сравнивать не с чем.
        let status = GitStatus.parse("# branch.head feature/новая\n")

        // nil, а не 0: «сравнивать не с чем» и «расхождения нет» — разные
        // вещи, и на этом различии держится причина, по которой Push в меню
        // гаснет с подписью «No upstream branch». Схлопни их в ноль — пункт
        // выглядел бы рабочим и падал бы при нажатии.
        #expect(status.ahead == nil)
        #expect(status.behind == nil)
        #expect(status.branch == "feature/новая")
    }
}
