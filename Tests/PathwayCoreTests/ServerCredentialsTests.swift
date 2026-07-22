import Foundation
import Testing

@testable import PathwayCore

@Suite("Учётные данные серверов")
struct ServerCredentialsTests {
    private let server = ServerAddress(scheme: "smb", host: "nas.local", share: "Общие")
    private let other = ServerAddress(scheme: "smb", host: "other.local", share: "Архив")

    @Test("сохранённые данные читаются обратно")
    func savesAndLoads() throws {
        let store = InMemoryCredentialStore()

        try store.save(user: "alex", password: "секрет", for: server)

        let loaded = try #require(store.load(for: server))
        #expect(loaded.user == "alex")
        #expect(loaded.password == "секрет")
    }

    @Test("для незнакомого сервера данных нет")
    func missingServerReturnsNil() {
        let store = InMemoryCredentialStore()

        #expect(store.load(for: server) == nil)
    }

    @Test("данные разных серверов не смешиваются")
    func serversAreIndependent() throws {
        let store = InMemoryCredentialStore()

        try store.save(user: "alex", password: "один", for: server)
        try store.save(user: "boris", password: "два", for: other)

        #expect(store.load(for: server)?.user == "alex")
        #expect(store.load(for: other)?.user == "boris")
    }

    @Test("повторное сохранение заменяет прежний пароль")
    func saveOverwrites() throws {
        let store = InMemoryCredentialStore()

        try store.save(user: "alex", password: "старый", for: server)
        try store.save(user: "alex", password: "новый", for: server)

        #expect(store.load(for: server)?.password == "новый")
    }

    @Test("удаление стирает данные")
    func deleteRemoves() throws {
        let store = InMemoryCredentialStore()
        try store.save(user: "alex", password: "секрет", for: server)

        try store.delete(for: server)

        #expect(store.load(for: server) == nil)
    }

    @Test("удаление несуществующей записи не считается ошибкой")
    func deleteMissingIsNotAnError() throws {
        let store = InMemoryCredentialStore()

        try store.delete(for: server)
    }

    @Test("ключом служит полный адрес, а не только хост")
    func keyIncludesShare() throws {
        let store = InMemoryCredentialStore()
        let sameHostOtherShare = ServerAddress(scheme: "smb", host: "nas.local", share: "Архив")

        try store.save(user: "alex", password: "секрет", for: server)

        #expect(store.load(for: sameHostOtherShare) == nil)
    }
}

/// Настоящая Связка ключей. Тест ручной: он пишет в Связку пользователя и на CI
/// без разблокированной связки падает, поэтому включается переменной среды.
@Suite("Связка ключей", .disabled(if: ProcessInfo.processInfo.environment["PATHWAY_KEYCHAIN_TESTS"] == nil))
struct KeychainCredentialStoreTests {
    @Test("запись переживает обращение к настоящей Связке ключей")
    func roundTripsThroughKeychain() throws {
        let store = KeychainCredentialStore()
        // Отдельный хост на каждый прогон, чтобы не мешать реальным записям.
        let server = ServerAddress(scheme: "smb", host: "pathway-test-\(UUID().uuidString).invalid", share: "Тест")
        defer { try? store.delete(for: server) }

        try store.save(user: "alex", password: "секрет", for: server)
        let loaded = try #require(store.load(for: server))

        #expect(loaded.user == "alex")
        #expect(loaded.password == "секрет")

        try store.delete(for: server)
        #expect(store.load(for: server) == nil)
    }
}
