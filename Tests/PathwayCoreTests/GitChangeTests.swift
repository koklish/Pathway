import Foundation
import Testing

@testable import PathwayCore

@Suite("Разбор списка изменённых файлов")
struct GitChangeTests {

    @Test("изменённый в рабочем дереве файл не отмечен как готовый к коммиту")
    func parsesUnstagedModification() {
        // XY = «.M»: индекс чист, рабочее дерево изменено.
        let output = "1 .M N... 100644 100644 100644 abc def Sources/PathwayCore/GitService.swift"

        let changes = GitChange.parse(output)

        #expect(changes.count == 1)
        #expect(changes[0].path == "Sources/PathwayCore/GitService.swift")
        #expect(changes[0].status == .modified)
        #expect(!changes[0].isStaged)
    }

    @Test("добавленный в индекс файл отмечен как готовый к коммиту")
    func parsesStagedAddition() {
        let output = "1 A. N... 000000 100644 100644 000 abc Sources/PathwayCore/GitLog.swift"

        let changes = GitChange.parse(output)

        #expect(changes[0].status == .added)
        #expect(changes[0].isStaged)
    }

    @Test("файл, изменённый и в индексе, и в дереве, считается отмеченным частично")
    func parsesPartiallyStaged() {
        // XY = «MM»: часть правок добавлена, часть — нет. Галочка обязана быть
        // включённой: коммит эти правки возьмёт.
        let output = "1 MM N... 100644 100644 100644 abc def Sources/Pathway/MainWindow.swift"

        let changes = GitChange.parse(output)

        #expect(changes[0].isStaged)
        #expect(changes[0].isPartiallyStaged)
    }

    @Test("удалённый файл получает свой статус")
    func parsesDeletion() {
        let output = "1 .D N... 100644 100644 000000 abc def Sources/Old.swift"

        let changes = GitChange.parse(output)

        #expect(changes[0].status == .deleted)
    }

    @Test("неотслеживаемый файл не отмечен и не может быть отмечен частично")
    func parsesUntracked() {
        let output = "? Sources/.DS_Store"

        let changes = GitChange.parse(output)

        #expect(changes[0].path == "Sources/.DS_Store")
        #expect(changes[0].status == .untracked)
        #expect(!changes[0].isStaged)
        #expect(!changes[0].isPartiallyStaged)
    }

    @Test("конфликтный файл получает свой статус, а не считается изменённым")
    func parsesConflict() {
        // Конфликт нельзя закоммитить как обычную правку: панель обязана
        // отличать его, чтобы не предлагать галочку там, где нужен терминал.
        let output = "u UU N... 100644 100644 100644 100644 abc def ghi Sources/Conflict.swift"

        let changes = GitChange.parse(output)

        #expect(changes[0].status == .conflicted)
        #expect(changes[0].path == "Sources/Conflict.swift")
    }

    @Test("переименованный файл показывает и новое имя, и прежнее")
    func parsesRename() {
        // Формат записи 2: после пути идёт \t и старый путь. Без старого имени
        // строка «Переименован» в панели ничего не сообщала бы.
        let output = "2 R. N... 100644 100644 100644 abc def R100 Sources/New.swift\tSources/Old.swift"

        let changes = GitChange.parse(output)

        #expect(changes[0].path == "Sources/New.swift")
        #expect(changes[0].oldPath == "Sources/Old.swift")
        #expect(changes[0].status == .renamed)
    }

    @Test("путь с пробелами не разрывается на два файла")
    func keepsSpacesInPath() {
        let output = "1 .M N... 100644 100644 100644 abc def Мои документы/файл с пробелами.txt"

        let changes = GitChange.parse(output)

        #expect(changes.count == 1)
        #expect(changes[0].path == "Мои документы/файл с пробелами.txt")
    }

    @Test("кириллическое имя раскавычивается из восьмеричных последовательностей")
    func decodesQuotedCyrillicPath() {
        // git закавычивает всё, что вне ASCII, и пишет байты в \nnn. Без
        // раскавычивания панель показывала бы «\321\204\320\260...» вместо
        // имени — а в этом проекте русские имена файлов обычны.
        let output = #"1 .M N... 100644 100644 100644 abc def "sub/\321\204\320\260\320\271\320\273.txt""#

        let changes = GitChange.parse(output)

        #expect(changes[0].path == "sub/файл.txt")
    }

    @Test("экранированная кавычка в имени возвращается сама собой")
    func decodesEscapedQuote() {
        // Имя с кавычкой git тоже экранирует — обратным слэшем, а не \nnn.
        let output = #"1 .M N... 100644 100644 100644 abc def "стран\"ное.txt""#

        let changes = GitChange.parse(output)

        #expect(changes[0].path == #"стран"ное.txt"#)
    }

    @Test("строки заголовка ветки в список файлов не попадают")
    func skipsBranchHeaders() {
        let output = """
        # branch.oid 88675656a7fcd1786816432b95f461836dc842ca
        # branch.head main
        # branch.ab +3 -2
        1 .M N... 100644 100644 100644 abc def Sources/A.swift
        """

        let changes = GitChange.parse(output)

        #expect(changes.count == 1)
        #expect(changes[0].path == "Sources/A.swift")
    }

    @Test("имя файла берётся из пути без папок")
    func exposesFileName() {
        let output = "1 .M N... 100644 100644 100644 abc def Sources/PathwayCore/GitLog.swift"

        let changes = GitChange.parse(output)

        #expect(changes[0].name == "GitLog.swift")
        #expect(changes[0].directory == "Sources/PathwayCore")
    }

    @Test("файл в корне репозитория показывает пустую папку, а не точку")
    func rootFileHasEmptyDirectory() {
        let output = "1 .M N... 100644 100644 100644 abc def README.md"

        let changes = GitChange.parse(output)

        #expect(changes[0].name == "README.md")
        #expect(changes[0].directory.isEmpty)
    }

    @Test("чистое дерево даёт пустой список")
    func cleanTreeGivesNothing() {
        #expect(GitChange.parse("# branch.head main").isEmpty)
        #expect(GitChange.parse("").isEmpty)
    }
}

@Suite("Разбор изменений на живом репозитории")
struct GitChangeLiveTests {

    /// Вывод настоящего git на репозитории с переименованием, русским именем
    /// с пробелами и неотслеживаемым файлом. Снят с git 2.x дословно.
    ///
    /// Синтетические строки в соседнем сьюте проверяют правила разбора, а этот
    /// тест — что правила сняты с настоящего формата, а не с его пересказа.
    private let output = """
    2 R. N... 100644 100644 100644 7898192261 7898192261 R100 new.txt\told.txt
    1 .M N... 100644 100644 100644 6178079822 6178079822 "sub/\\321\\204\\320\\260\\320\\271\\320\\273 \\321\\201 \\320\\277\\321\\200\\320\\276\\320\\261\\320\\265\\320\\273\\320\\260\\320\\274\\320\\270.txt"
    ? untracked.txt
    """

    @Test("разбирает вывод настоящего git целиком")
    func parsesRealOutput() {
        let changes = GitChange.parse(output)

        #expect(changes.count == 3)
        #expect(changes[0].path == "new.txt")
        #expect(changes[0].oldPath == "old.txt")
        #expect(changes[0].status == .renamed)
        #expect(changes[1].path == "sub/файл с пробелами.txt")
        #expect(changes[1].status == .modified)
        #expect(changes[2].path == "untracked.txt")
        #expect(changes[2].status == .untracked)
    }
}
