import Foundation
import Testing

@testable import PathwayCore

@Suite("Переподключение отвалившихся томов")
@MainActor
struct ReconnectStaleVolumesTests {
    private let server = ServerAddress(scheme: "smb", host: "nas.local", share: "Общие")
    private var mountPoint: URL { URL(fileURLWithPath: "/Volumes/Общие") }

    /// Подключение с учтённым томом и подменённой пробой.
    ///
    /// `responding` решает, отвечает ли том: настоящая проба полезла бы в
    /// файловую систему и зависела бы от того, что смонтировано на машине.
    private func makeConnection(
        responding: Bool,
        behaviour: RecordingMounter.Behaviour = .mounted(URL(fileURLWithPath: "/Volumes/Общие"))
    ) -> (ServerConnection, RecordingMounter, InMemoryCredentialStore) {
        let defaults = UserDefaults(suiteName: "tests.reconnect.\(UUID().uuidString)")!
        let mounter = RecordingMounter(behaviour)
        let credentials = InMemoryCredentialStore()
        let mounted = MountedServers()
        // Через adopt, а не remember: переподключение обходит тома, видимые
        // системе, — remember положил бы точку мимо этого списка.
        mounted.adopt([MountedServers.NetworkVolume(server: server, mountPoint: mountPoint)])

        let connection = ServerConnection(
            bookmarks: ServerBookmarks(defaults: defaults),
            credentials: credentials,
            mounter: mounter,
            mounted: mounted,
            probe: { _ in responding }
        )
        return (connection, mounter, credentials)
    }

    @Test("залипший том принудительно отключается и монтируется заново")
    func staleVolumeIsForcedOffAndRemounted() async {
        let (connection, mounter, _) = makeConnection(responding: false)

        await connection.reconnectStaleVolumes()

        #expect(mounter.forceUnmounted == [mountPoint])
        #expect(mounter.callCount == 1)
        #expect(connection.mounted.isMounted(server))
    }

    @Test("живой том не трогается вовсе")
    func healthyVolumeIsLeftAlone() async {
        let (connection, mounter, _) = makeConnection(responding: true)

        await connection.reconnectStaleVolumes()

        #expect(mounter.forceUnmounted.isEmpty)
        #expect(mounter.callCount == 0, "перемонтирования живого тома быть не должно")
    }

    @Test("залипший том снимается принудительно, а не обычным отключением")
    func staleVolumeUsesForcedPath() async {
        let (connection, mounter, _) = makeConnection(responding: false)

        await connection.reconnectStaleVolumes()

        // Обычный unmount идёт через NSWorkspace и на залипшем томе виснет сам.
        #expect(mounter.unmounted.isEmpty)
        #expect(mounter.forceUnmounted == [mountPoint])
    }

    @Test("неудачное переподключение оставляет том отключённым и не рождает текста ошибки")
    func failedRemountLeavesVolumeDetachedSilently() async {
        // Сервер недоступен — ноутбук открыли дома, без VPN.
        let (connection, _, _) = makeConnection(
            responding: false, behaviour: .failure(Int32(EHOSTUNREACH))
        )

        await connection.reconnectStaleVolumes()

        #expect(connection.mounted.isMounted(server) == false)
    }

    @Test("залипший том отключается принудительно даже тогда, когда переподключение не удалось")
    func staleVolumeIsForcedOffEvenWhenRemountFails() async {
        let (connection, mounter, _) = makeConnection(
            responding: false, behaviour: .failure(Int32(EHOSTUNREACH))
        )

        await connection.reconnectStaleVolumes()

        // Оставленный залипший том продолжил бы вешать приложение при каждом
        // обращении — ровно то, на что жалуются пользователи.
        #expect(mounter.forceUnmounted == [mountPoint])
    }

    @Test("переподключение берёт сохранённый пароль, а не входит гостем")
    func remountUsesSavedCredentials() async throws {
        let (connection, mounter, credentials) = makeConnection(responding: false)
        try credentials.save(user: "alex", password: "секрет", for: server)

        await connection.reconnectStaleVolumes()

        #expect(mounter.lastUser == "alex")
        #expect(mounter.lastPassword == "секрет")
        #expect(mounter.lastGuest == false)
    }

    @Test("сбой принудительного отключения не отменяет попытку переподключения")
    func remountProceedsEvenIfForceUnmountFails() async {
        let (connection, mounter, _) = makeConnection(responding: false)
        // Том мог сняться сам, пока мы к нему шли: это не повод бросать дело.
        mounter.forceUnmountError = MountError(code: Int32(EINVAL), host: "nas.local")

        await connection.reconnectStaleVolumes()

        #expect(mounter.callCount == 1)
    }

    @Test("без учтённых томов не делает ничего")
    func noVolumesMeansNoWork() async {
        let defaults = UserDefaults(suiteName: "tests.reconnect.\(UUID().uuidString)")!
        let mounter = RecordingMounter(.mounted(mountPoint))
        let connection = ServerConnection(
            bookmarks: ServerBookmarks(defaults: defaults),
            credentials: InMemoryCredentialStore(),
            mounter: mounter,
            mounted: MountedServers(),
            probe: { _ in false }
        )

        await connection.reconnectStaleVolumes()

        #expect(mounter.forceUnmounted.isEmpty)
        #expect(mounter.callCount == 0)
    }
}

@Suite("Проба точки монтирования")
struct MountProbeTests {
    @Test("существующая папка отвечает")
    func existingPathResponds() async {
        #expect(await MountedServers.responds(at: URL(fileURLWithPath: "/tmp")))
    }

    @Test("несуществующий путь не отвечает, а не ждёт таймаута")
    func missingPathDoesNotRespond() async {
        let missing = URL(fileURLWithPath: "/Volumes/нет-такого-\(UUID().uuidString)")

        #expect(await MountedServers.responds(at: missing) == false)
    }

    @Test("отвечающий том возвращает ответ быстрее таймаута, а не по его истечении")
    func respondingVolumeReturnsBeforeTimeout() async {
        // Стережёт саму гонку. Задачи, созданные сбоку от группы, cancelAll не
        // снимает, и ожидание их value держало бы нас весь срок таймаута даже
        // при мгновенном ответе statfs — проба «успешно» работала бы, но
        // каждый живой том стоил бы двух секунд.
        let started = ContinuousClock.now

        let answered = await MountedServers.responds(
            at: URL(fileURLWithPath: "/tmp"), timeout: .seconds(10)
        )

        #expect(answered)
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
