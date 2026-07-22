import Foundation
import Testing

@testable import PathwayCore

@Suite("Поиск Claude CLI")
struct ClaudeCLITests {
    /// Временная папка с исполняемым файлом claude внутри.
    private func makeDirectory(
        withExecutable executable: Bool,
        name: String = "claude"
    ) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: binary.path
        )
        return directory
    }

    @Test("находит исполняемый claude среди кандидатов")
    func findsExecutable() throws {
        let directory = try makeDirectory(withExecutable: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let found = ClaudeCLI.locate(searchPaths: [directory.appendingPathComponent("claude").path])

        #expect(found == directory.appendingPathComponent("claude").path)
    }

    @Test("файл без бита запуска не считается установленным CLI")
    func ignoresNonExecutableFile() throws {
        let directory = try makeDirectory(withExecutable: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let found = ClaudeCLI.locate(searchPaths: [directory.appendingPathComponent("claude").path])

        #expect(found == nil)
    }

    @Test("когда claude нигде не лежит, возвращается nil")
    func returnsNilWhenMissing() {
        let found = ClaudeCLI.locate(searchPaths: ["/nowhere/claude", "/also/missing/claude"])

        #expect(found == nil)
    }

    @Test("берётся первый подходящий кандидат по порядку")
    func prefersEarlierCandidate() throws {
        let first = try makeDirectory(withExecutable: true)
        let second = try makeDirectory(withExecutable: true)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let found = ClaudeCLI.locate(searchPaths: [
            first.appendingPathComponent("claude").path,
            second.appendingPathComponent("claude").path,
        ])

        #expect(found == first.appendingPathComponent("claude").path)
    }

    @Test("несуществующий кандидат не мешает найти следующий")
    func skipsMissingCandidates() throws {
        let directory = try makeDirectory(withExecutable: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let found = ClaudeCLI.locate(searchPaths: [
            "/definitely/not/here/claude",
            directory.appendingPathComponent("claude").path,
        ])

        #expect(found == directory.appendingPathComponent("claude").path)
    }

    @Test("список кандидатов включает штатную установку Claude Code")
    func candidatesCoverStandardInstall() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let candidates = ClaudeCLI.candidatePaths()

        // GUI-приложение стартует с урезанным PATH, поэтому важные места перечислены явно.
        #expect(candidates.contains("\(home)/.claude/local/claude"))
        #expect(candidates.contains("/opt/homebrew/bin/claude"))
        #expect(candidates.contains("/usr/local/bin/claude"))
    }
}
