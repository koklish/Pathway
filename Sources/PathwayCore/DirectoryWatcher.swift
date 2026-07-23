import Foundation

/// Что произошло в отслеживаемой папке.
///
/// Одно поле, а не перечисление событий по файлам: FSEvents при коалесцировании
/// и на сетевых томах отдаёт события пачкой, без надёжного соответствия
/// «одно событие — один файл». Строить дифф на путях из события значило бы
/// полагаться на данные, которых система не гарантирует, — состав папки
/// потребитель всё равно перечитывает сам.
public struct DirectoryChange: Sendable {
    /// Событие несло флаг ItemModified: содержимое существующего объекта
    /// изменилось, и прочитанные размеры с датами устарели.
    public let hasModifications: Bool

    public init(hasModifications: Bool) {
        self.hasModifications = hasModifications
    }
}

/// Слежение за содержимым одной папки.
///
/// Протокол, а не конкретный тип: настоящий FSEvents в тесте потребовал бы
/// писать в файловую систему и ждать событие неопределённое время. Через
/// подмену проверяется вся реакция модели на изменение, без обращения к диску.
@MainActor
public protocol DirectoryWatching: AnyObject {
    /// Начинает следить за папкой, заменяя предыдущую. Колбэк приходит на главном потоке.
    func start(_ directory: URL, onChange: @escaping @MainActor (DirectoryChange) -> Void)
    func stop()
}

/// Слежение за папкой через FSEvents.
@MainActor
public final class DirectoryWatcher: DirectoryWatching {
    private var stream: Stream?
    private let queue = DispatchQueue(label: "com.pathway.directory-watcher")

    public init() {}

    deinit {
        // Поток нельзя оставить живым: он держит контекст с колбэком. deinit
        // не изолирован, поэтому FSEventStreamRef завёрнут в Sendable-держатель —
        // сами вызовы FSEvents потокобезопасны.
        stream?.dispose()
    }

    /// Владелец потока FSEvents. Отдельный тип, потому что FSEventStreamRef —
    /// не Sendable, а освобождать поток нужно из неизолированного deinit.
    /// @unchecked: FSEventStreamRef — это OpaquePointer, который компилятор
    /// Sendable не считает, а сами вызовы FSEvents потокобезопасны.
    private final class Stream: @unchecked Sendable {
        let ref: FSEventStreamRef

        init(_ ref: FSEventStreamRef) {
            self.ref = ref
        }

        /// Порядок обязателен: остановить, отвязать от очереди, освободить.
        func dispose() {
            FSEventStreamStop(ref)
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
        }
    }

    public func start(_ directory: URL, onChange: @escaping @MainActor (DirectoryChange) -> Void) {
        stop()

        // Прыжок на главный поток делаем здесь, а не в колбэке ядра: тип
        // хранимого замыкания должен остаться неизолированным (см. Handler).
        let handler = Handler(
            onChange: { change in Task { @MainActor in onChange(change) } },
            directory: Self.canonicalPath(directory)
        )
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(handler).toOpaque(),
            retain: nil,
            // Свободная функция, а не замыкание по месту: замыкание внутри
            // @MainActor-класса наследует его изоляцию, а ядро зовёт release
            // со своей очереди внутри FSEventStreamDeallocate — проверка
            // изоляции валила процесс через dispatch_assert_queue_fail.
            release: releaseHandler,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                // Без FileEvents события приходят на уровне каталога, и флаг
                // ItemModified не отличить от создания.
                | kFSEventStreamCreateFlagFileEvents
                // Первое событие пачки — сразу, latency работает окном после него.
                // С отложенной доставкой создание одного файла ждало бы впустую.
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            [directory.path] as CFArray,
            // История не нужна: список только что прочитан.
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // Коалесцирование делает система: пачка из тридцати созданных файлов
            // приходит одним вызовом, поэтому своего дебаунса в проекте нет.
            0.3,
            flags
        ) else {
            // Освобождаем то, что забрал passRetained: колбэк-release не позовётся.
            Unmanaged<Handler>.fromOpaque(context.info!).release()
            return
        }

        self.stream = Stream(stream)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        stream?.dispose()
        stream = nil
    }

    /// Держатель колбэка: FSEvents принимает только указатель, замыкание в него не положить.
    ///
    /// Хранит @Sendable-замыкание, а не @MainActor: освобождение контекста ядро
    /// выполняет на своей очереди, внутри FSEventStreamDeallocate. Хранимое здесь
    /// @MainActor-замыкание проверялось бы на изоляцию при разрушении Handler и
    /// роняло бы процесс через dispatch_assert_queue_fail. Переход на главный
    /// поток поэтому спрятан внутрь замыкания, а не выражен его типом.
    fileprivate final class Handler: @unchecked Sendable {
        let onChange: @Sendable (DirectoryChange) -> Void
        /// Канонический путь папки — в том виде, в каком пути приходят от ядра.
        let directory: String

        init(onChange: @escaping @Sendable (DirectoryChange) -> Void, directory: String) {
            self.onChange = onChange
            self.directory = directory
        }
    }

    /// Путь в том виде, в каком его отдаёт FSEvents.
    ///
    /// Только C-функция realpath разворачивает /var в /private/var: и
    /// resolvingSymlinksInPath, и standardizedFileURL оставляют путь как есть.
    /// Без этого ни одно событие во временных папках не совпало бы с
    /// отслеживаемой, и все они отсеивались бы как чужие.
    private static func canonicalPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url.path }
        return String(cString: buffer)
    }
}

/// Освобождает контекст потока. Вне класса по той же причине, что и eventCallback:
/// ядро зовёт это с собственной очереди, и изоляция здесь недопустима.
private func releaseHandler(_ info: UnsafeRawPointer?) {
    guard let info else { return }
    Unmanaged<DirectoryWatcher.Handler>.fromOpaque(info).release()
}

/// Колбэк FSEvents. Свободная функция, а не замыкание: C-указатель на функцию
/// не может захватывать контекст.
private let eventCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info else { return }
    let handler = Unmanaged<DirectoryWatcher.Handler>.fromOpaque(info).takeUnretainedValue()

    // С флагом UseCFTypes пути приходят готовым CFArray, а не C-массивом строк.
    guard let list = unsafeBitCast(paths, to: CFArray.self) as? [String] else { return }

    let watched = handler.directory
    var relevant = false
    var modified = false
    for index in 0..<count where index < list.count {
        let url = URL(fileURLWithPath: list[index])
        // FSEvents рекурсивен по своей природе: изменения в подпапках на состав
        // нашего списка не влияют, и их надо отсечь здесь. Событие о самой папке
        // тоже пропускаем — оно приходит вместе с событием о её содержимом.
        //
        // Сравниваем по .path, а не по URL: адрес каталога несёт завершающий
        // слэш, и целые URL разошлись бы на нём при совпадающих путях.
        guard url.deletingLastPathComponent().path == watched else { continue }
        relevant = true
        if flags[index] & UInt32(kFSEventStreamEventFlagItemModified) != 0 {
            modified = true
        }
    }
    guard relevant else { return }

    // Переход на главный поток спрятан внутри самого замыкания — см. Handler.
    handler.onChange(DirectoryChange(hasModifications: modified))
}
