import Foundation

/// Переносит учётные данные из Связки ключей в основное хранилище — по одному,
/// в момент, когда пароль впервые понадобился.
///
/// Отдельный тип, а не ветвление внутри `FileCredentialStore`: перенос временный
/// и однажды удалится целиком, а хранилище останется. Убрать его можно будет
/// заменой одной строки в `ServerConnection.init` — через несколько версий,
/// когда у коллег не останется записей в Связке.
///
/// Разовый перенос всех записей при запуске отвергнут: он показал бы диалог
/// Связки на каждый сохранённый сервер сразу, включая те, которыми не
/// пользуются. Здесь диалог возникает не более одного раза на сервер и только
/// при реальном подключении к нему.
public struct MigratingCredentialStore: CredentialStoring {
    private let primary: any CredentialStoring
    private let legacy: any CredentialStoring

    public init(primary: any CredentialStoring, legacy: any CredentialStoring) {
        self.primary = primary
        self.legacy = legacy
    }

    /// Читает пароль, при необходимости перенося его из Связки ключей.
    ///
    /// Порядок обязателен: сначала запись в основное хранилище, потом удаление
    /// из Связки. Обратный при сбое записи потерял бы пароль совсем.
    ///
    /// Удаление диалога не вызывает, поэтому второй раз тот же сервер не
    /// спросит. Отмена диалога пользователем даёт nil — приложение покажет
    /// экран входа, как при отсутствующем пароле, и предложит перенос снова при
    /// следующей попытке: запоминать отказ нельзя, пользователь мог промахнуться.
    public func load(for server: ServerAddress) -> ServerCredentials? {
        if let found = primary.load(for: server) { return found }

        guard let migrated = legacy.load(for: server) else { return nil }
        try? primary.save(user: migrated.user, password: migrated.password, for: server)
        try? legacy.delete(for: server)
        return migrated
    }

    /// Ни здесь, ни в `savedUser` перенести нечего: пароля без `load` не добыть.
    /// Спрашивать Связку можно свободно — на атрибуты она отвечает без диалога.
    public func exists(for server: ServerAddress) -> Bool {
        primary.exists(for: server) || legacy.exists(for: server)
    }

    public func savedUser(for server: ServerAddress) -> String? {
        primary.savedUser(for: server) ?? legacy.savedUser(for: server)
    }

    /// Новые пароли в Связку не попадают никогда.
    public func save(user: String, password: String, for server: ServerAddress) throws {
        try primary.save(user: user, password: password, for: server)
    }

    /// Стирает из обоих: «Забыть пароль», не тронувший Связку, воскресил бы
    /// забытый пароль при следующем подключении.
    public func delete(for server: ServerAddress) throws {
        try primary.delete(for: server)
        try legacy.delete(for: server)
    }
}
