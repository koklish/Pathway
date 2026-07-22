import Foundation
import Observation

/// Состояние диалога «Подключение к серверу».
@Observable
@MainActor
public final class ConnectServerModel {
    /// Какой из экранов макета показан.
    public enum Step: Equatable {
        case address
        /// Выбор папки на сервере, когда адрес указан без неё.
        case shares(host: String)
        case credentials(ServerAddress)
        /// Редактирование настроек сохранённого сервера.
        case editing(ServerAddress)
    }

    public enum Login: String, CaseIterable, Sendable {
        case guest, registered

        public var label: String {
            switch self {
            case .guest: "Гость"
            case .registered: "Зарегистрированный пользователь"
            }
        }
    }

    public private(set) var step: Step = .address
    public var addressText = ""
    public var login: Login = .registered
    public var username = ""
    public var password = ""
    public var saveToKeychain = true
    public private(set) var isConnecting = false
    public var errorMessage: String?
    /// Подсказка над формой — например, что сохранённый пароль больше не подходит.
    public private(set) var noticeMessage: String?
    /// У сервера уже есть пароль в Связке ключей: поле показывает «сохранён».
    public private(set) var hasStoredPassword = false

    /// Папки, которые сервер согласился показать.
    public private(set) var shares: [Share] = []
    public private(set) var isLoadingShares = false

    private let connection: ServerConnection
    private let browser: any ShareBrowsing

    public var bookmarks: ServerBookmarks { connection.bookmarks }

    /// Вызывается после успешного монтирования — панель уходит на этот том.
    public var onMounted: ((URL) -> Void)?
    /// Вызывается, когда настройки сохранены и диалог пора закрыть.
    public var onSettingsSaved: (() -> Void)?

    public init(
        connection: ServerConnection = ServerConnection(),
        browser: any ShareBrowsing = ShareBrowser()
    ) {
        self.connection = connection
        self.browser = browser
    }

    public var canSubmit: Bool {
        switch step {
        case .address:
            return ServerAddress.parse(addressText) != nil && !isConnecting && !isLoadingShares
        case .shares:
            return !isConnecting
        case .credentials:
            return !isConnecting && (login == .guest || !username.isEmpty)
        case .editing:
            return ServerAddress.parse(addressText) != nil
                && (login == .guest || !username.isEmpty)
        }
    }

    /// Хост, на котором идёт авторизация, — для подзаголовка второго экрана.
    public var authenticatingHost: String? {
        switch step {
        case .credentials(let server), .editing(let server): server.host
        case .shares(let host): host
        case .address: nil
        }
    }

    public var isChoosingShare: Bool {
        if case .shares = step { return true }
        return false
    }

    public var isEditing: Bool {
        if case .editing = step { return true }
        return false
    }

    /// Подключён ли редактируемый сервер прямо сейчас — от этого зависит подсказка
    /// о том, что изменения применятся при следующем подключении.
    public var isEditingMountedServer: Bool {
        guard case .editing(let server) = step else { return false }
        return connection.mounted.isMounted(server)
    }

    // MARK: - Открытие диалога

    public func startNewConnection() {
        step = .address
        addressText = ""
        username = ""
        password = ""
        shares = []
        login = .registered
        saveToKeychain = true
        errorMessage = nil
        noticeMessage = nil
        hasStoredPassword = false
    }

    /// Открывает форму настроек сохранённого сервера.
    public func startEditing(_ server: ServerAddress) {
        step = .editing(server)
        addressText = server.key.removingPercentEncoding ?? server.key
        username = connection.savedUser(for: server) ?? ""
        password = ""
        hasStoredPassword = connection.hasSavedPassword(for: server)
        login = connection.bookmarks.bookmark(for: server)?.isGuest == true ? .guest : .registered
        saveToKeychain = true
        errorMessage = nil
        noticeMessage = nil
    }

    public func selectBookmark(_ bookmark: ServerBookmark) {
        addressText = bookmark.address.removingPercentEncoding ?? bookmark.address
    }

    public func goBackToAddress() {
        step = .address
        password = ""
        shares = []
        errorMessage = nil
        noticeMessage = nil
    }

    // MARK: - Действия

    /// Кнопка «Подключиться» или «Сохранить» — в зависимости от экрана.
    public func submit() async {
        switch step {
        case .address:
            guard let server = ServerAddress.parse(addressText) else {
                errorMessage = "Не удалось разобрать адрес. Пример: smb://server/share"
                return
            }
            // Папка не указана — покажем, что есть на сервере, вместо того чтобы
            // молча подключить первую попавшуюся.
            if server.share.isEmpty {
                await loadShares(of: server.host)
            } else {
                await connect(server)
            }

        case .shares(let host):
            // Кнопка на этом шаге подключает к выбранной папке; если ничего
            // не выбрано, подключаемся к серверу целиком — как раньше.
            await connect(ServerAddress(scheme: "smb", host: host, share: ""))

        case .credentials(let server):
            await connect(server, withCredentials: true)

        case .editing(let server):
            saveSettings(for: server)
        }
    }

    /// Спрашивает у сервера список папок и показывает шаг выбора.
    public func loadShares(of host: String) async {
        isLoadingShares = true
        errorMessage = nil
        defer { isLoadingShares = false }

        let browser = self.browser
        // Учётные данные передаём, если пользователь их уже ввёл: на серверах,
        // которые не показывают список гостю, без них ответа не будет.
        let user = login == .registered && !username.isEmpty ? username : nil
        let secret = login == .registered && !password.isEmpty ? password : nil

        do {
            let found = try await Task.detached {
                try browser.shares(of: host, user: user, password: secret)
            }.value
            shares = found
            step = .shares(host: host)
            if found.isEmpty {
                noticeMessage = "Сервер не показал ни одной папки. Можно ввести адрес папки вручную."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Подключается к выбранной папке сервера.
    public func selectShare(_ share: Share, host: String) async {
        let server = ServerAddress(scheme: "smb", host: host, share: share.name)
        addressText = server.key.removingPercentEncoding ?? server.key
        await connect(server)
    }

    private func saveSettings(for server: ServerAddress) {
        guard let updated = ServerAddress.parse(addressText) else {
            errorMessage = "Не удалось разобрать адрес. Пример: smb://server/share"
            return
        }
        connection.updateSettings(
            for: server,
            user: username,
            password: password,
            isGuest: login == .guest,
            newAddress: updated == server ? nil : updated
        )
        password = ""
        onSettingsSaved?()
    }

    private func connect(_ server: ServerAddress, withCredentials: Bool = false) async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let outcome = await connection.connect(
            to: server,
            user: withCredentials && login == .registered ? username : nil,
            password: withCredentials && login == .registered ? password : nil,
            asGuest: withCredentials && login == .guest,
            remember: saveToKeychain
        )

        switch outcome {
        case .mounted(let point):
            password = ""
            onMounted?(point)
        case .needsCredentials(let suggestedUser, let reason):
            step = .credentials(server)
            if let suggestedUser, username.isEmpty { username = suggestedUser }
            password = ""
            noticeMessage = reason.message
        case .failed(let message):
            errorMessage = message
        }
    }
}
