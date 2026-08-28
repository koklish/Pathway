import Foundation
import Testing

@testable import PathwayCore

@Suite("Синхронное чтение веток")
struct BranchReaderTests {

    @Test("читает ветки настоящего репозитория, помечая текущую",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/git")))
    func readsRealRepository() throws {
        try withTempDir { dir in
            let git = URL(fileURLWithPath: "/usr/bin/git")
            func run(_ arguments: [String]) throws {
                let process = Process()
                process.executableURL = git
                process.arguments = arguments
                process.currentDirectoryURL = dir
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
            }

            try run(["init", "-q", "-b", "главная", "."])
            try run(["config", "user.email", "t@t"])
            try run(["config", "user.name", "t"])
            try "текст".write(to: dir.appendingPathComponent("файл.txt"),
                              atomically: true, encoding: .utf8)
            try run(["add", "-A"])
            try run(["commit", "-qm", "первый"])
            try run(["branch", "вторая"])

            let branches = BranchReader.branches(at: dir)

            #expect(Set(branches.map(\.name)) == ["главная", "вторая"])
            #expect(branches.first { $0.isCurrent }?.name == "главная")
            #expect(branches.allSatisfy { !$0.isRemote })
        }
    }

    @Test("папка без репозитория даёт пустой список, а не падение")
    func plainFolderGivesEmptyList() throws {
        try withTempDir { dir in
            // Молча пустой: меню строится в любом случае, и показать ошибку
            // ему всё равно негде.
            #expect(BranchReader.branches(at: dir).isEmpty)
        }
    }

    @Test("отсутствие git не роняет чтение")
    func missingGitGivesEmptyList() throws {
        try withTempDir { dir in
            let branches = BranchReader.branches(
                at: dir,
                tool: URL(fileURLWithPath: "/несуществующий/git")
            )
            #expect(branches.isEmpty)
        }
    }
}
