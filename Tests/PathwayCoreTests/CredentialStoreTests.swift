import Foundation
import Testing
@testable import PathwayCore

/// Предсказуемый идентификатор машины: настоящий IOKit дал бы разное значение
/// на разных машинах, и проверить ключ шифрования было бы нечем.
private struct FixedMachine: MachineIdentifying {
    let identifier: String
}

private let nas = ServerAddress(scheme: "smb", host: "nas.local", share: "Общие")
private let archive = ServerAddress(scheme: "smb", host: "nas.local", share: "Архив")

private func makeStore(in dir: URL, machine: String = "MACHINE-A:501") -> FileCredentialStore {
    FileCredentialStore(
        fileURL: dir.appendingPathComponent("credentials.dat"),
        machine: FixedMachine(identifier: machine)
    )
}

@Suite("Файловое хранилище учётных данных")
struct FileCredentialStoreTests {

    @Test("сохраняет и возвращает логин с паролем")
    func savesAndLoads() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            try store.save(user: "ivan", password: "секрет", for: nas)

            #expect(store.load(for: nas) == ServerCredentials(user: "ivan", password: "секрет"))
        }
    }

    @Test("отдаёт nil для незнакомого адреса")
    func returnsNilForUnknownServer() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            try store.save(user: "ivan", password: "секрет", for: nas)

            #expect(store.load(for: archive) == nil)
            #expect(store.exists(for: archive) == false)
            #expect(store.savedUser(for: archive) == nil)
        }
    }

    @Test("удаляет запись, повторное удаление не ошибка")
    func deletesEntry() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            try store.save(user: "ivan", password: "секрет", for: nas)

            try store.delete(for: nas)
            #expect(store.load(for: nas) == nil)
            try store.delete(for: nas)
        }
    }

    @Test("повторное сохранение заменяет прежние логин и пароль")
    func overwritesEntry() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            try store.save(user: "ivan", password: "старый", for: nas)
            try store.save(user: "petr", password: "новый", for: nas)

            #expect(store.load(for: nas) == ServerCredentials(user: "petr", password: "новый"))
        }
    }

    @Test("ключом служит полный адрес, а не только хост")
    func keysByFullAddress() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            try store.save(user: "ivan", password: "первый", for: nas)
            try store.save(user: "petr", password: "второй", for: archive)

            #expect(store.load(for: nas)?.password == "первый")
            #expect(store.load(for: archive)?.password == "второй")
        }
    }

    @Test("переживает пересоздание хранилища")
    func survivesRecreation() throws {
        try withTempDir { dir in
            try makeStore(in: dir).save(user: "ivan", password: "секрет", for: nas)

            #expect(makeStore(in: dir).load(for: nas)?.password == "секрет")
        }
    }

    @Test("файл на диске не содержит пароля в открытом виде")
    func fileIsEncrypted() throws {
        try withTempDir { dir in
            let store = makeStore(in: dir)
            try store.save(user: "ivan", password: "СуперПароль123", for: nas)

            let raw = try Data(contentsOf: dir.appendingPathComponent("credentials.dat"))
            #expect(raw.range(of: Data("СуперПароль123".utf8)) == nil)
            #expect(raw.range(of: Data("ivan".utf8)) == nil)
            #expect(raw.range(of: Data(nas.key.utf8)) == nil)
        }
    }

    @Test("чужой ключ не расшифровывает файл: nil, а не мусор")
    func foreignKeyCannotRead() throws {
        try withTempDir { dir in
            try makeStore(in: dir, machine: "MACHINE-A:501")
                .save(user: "ivan", password: "секрет", for: nas)

            let foreign = makeStore(in: dir, machine: "MACHINE-B:501")
            #expect(foreign.load(for: nas) == nil)
            #expect(foreign.exists(for: nas) == false)
        }
    }

    @Test("права файла 0600: читать может только владелец")
    func fileIsPrivate() throws {
        try withTempDir { dir in
            try makeStore(in: dir).save(user: "ivan", password: "секрет", for: nas)

            let path = dir.appendingPathComponent("credentials.dat").path
            let permissions = try FileManager.default
                .attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            #expect(permissions?.int16Value == 0o600)
        }
    }

    @Test("повреждённый файл читается как пустое хранилище, а не падает")
    func corruptedFileReadsAsEmpty() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("credentials.dat")
            try Data("это не шифротекст".utf8).write(to: file)

            let store = makeStore(in: dir)
            #expect(store.load(for: nas) == nil)

            // Записывать поверх повреждённого файла хранилище обязано: спасать
            // нечитаемое нечем, а отказ оставил бы пользователя без сохранения.
            try store.save(user: "ivan", password: "секрет", for: nas)
            #expect(store.load(for: nas)?.password == "секрет")
        }
    }
}

@Suite("Перенос учётных данных из Связки ключей")
struct MigratingCredentialStoreTests {

    /// Основное хранилище — файловое, устаревшее — со счётчиками обращений:
    /// именно они стерегут отсутствие лишних чтений, то есть отсутствие диалога.
    private func makePair(in dir: URL) -> (MigratingCredentialStore, InMemoryCredentialStore) {
        let legacy = InMemoryCredentialStore()
        let store = MigratingCredentialStore(primary: makeStore(in: dir), legacy: legacy)
        return (store, legacy)
    }

    @Test("при наличии записи в файле Связку ключей не читает вовсе")
    func doesNotTouchLegacyWhenPrimaryHasEntry() throws {
        try withTempDir { dir in
            let (store, legacy) = makePair(in: dir)
            try store.save(user: "ivan", password: "секрет", for: nas)
            legacy.resetCounters()

            #expect(store.load(for: nas)?.password == "секрет")
            #expect(legacy.loadCount == 0)
        }
    }

    @Test("при промахе в файле берёт пароль из Связки ключей")
    func fallsBackToLegacy() throws {
        try withTempDir { dir in
            let (store, legacy) = makePair(in: dir)
            try legacy.save(user: "ivan", password: "старый", for: nas)

            #expect(store.load(for: nas) == ServerCredentials(user: "ivan", password: "старый"))
        }
    }

    @Test("после переноса запись появляется в файле и исчезает из Связки")
    func migratesEntry() throws {
        try withTempDir { dir in
            let (store, legacy) = makePair(in: dir)
            try legacy.save(user: "ivan", password: "старый", for: nas)

            _ = store.load(for: nas)

            #expect(makeStore(in: dir).load(for: nas)?.password == "старый")
            #expect(legacy.load(for: nas) == nil)
        }
    }

    @Test("после переноса повторное чтение Связку не трогает")
    func migratesOnlyOnce() throws {
        try withTempDir { dir in
            let (store, legacy) = makePair(in: dir)
            try legacy.save(user: "ivan", password: "старый", for: nas)
            _ = store.load(for: nas)
            legacy.resetCounters()

            #expect(store.load(for: nas)?.password == "старый")
            #expect(legacy.loadCount == 0)
        }
    }

    @Test("сохраняет только в файл: новые пароли в Связку не попадают")
    func savesOnlyToPrimary() throws {
        try withTempDir { dir in
            let (store, legacy) = makePair(in: dir)
            try store.save(user: "ivan", password: "секрет", for: nas)

            #expect(legacy.load(for: nas) == nil)
            #expect(makeStore(in: dir).load(for: nas)?.password == "секрет")
        }
    }

    @Test("удаляет из обоих хранилищ, а не только из файла")
    func deletesFromBoth() throws {
        try withTempDir { dir in
            let (store, legacy) = makePair(in: dir)
            try legacy.save(user: "ivan", password: "старый", for: nas)
            try store.save(user: "ivan", password: "новый", for: nas)

            try store.delete(for: nas)

            #expect(store.load(for: nas) == nil)
            #expect(legacy.load(for: nas) == nil)
        }
    }

    @Test("сообщает о сохранённом пароле, оставшемся в Связке ключей")
    func reportsLegacyEntry() throws {
        try withTempDir { dir in
            let (store, legacy) = makePair(in: dir)
            try legacy.save(user: "ivan", password: "старый", for: nas)

            #expect(store.exists(for: nas))
            #expect(store.savedUser(for: nas) == "ivan")
        }
    }
}
