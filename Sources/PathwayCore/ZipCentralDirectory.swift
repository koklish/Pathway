import Foundation

public enum ZipReadError: Error, Equatable {
    /// Сигнатуры конца центрального каталога нет — файл не ZIP или обрезан.
    case notAZipArchive
    case unreadable
}

/// Читает имена записей ZIP из центрального каталога.
///
/// Своя реализация вместо запуска `bsdtar`/`unzip` — по двум измеренным
/// причинам.
///
/// Скорость: запуск процесса стоит 2,5 мс, чтение хвоста файла — 0,03 мс. На
/// тысяче архивов это 2,5 секунды против трёх сотых, и разница видна
/// пользователю целиком, потому что архивы обходятся при каждом поиске.
///
/// Трафик: `bsdtar` перечисляет ZIP, проходя файл насквозь по локальным
/// заголовкам — на архиве в 95 МБ он вычитывает все 95 МБ. Центральный каталог
/// лежит в хвосте, и его достаточно: по сети это килобайты вместо мегабайтов
/// на каждый архив. Замер и проверка описаны в спеке поиска.
///
/// `unzip -Z1` читал бы тот же хвост, но **портит кириллицу**, подменяя байты
/// имени на «?» — для проекта, где все файлы названы по-русски, это
/// дисквалифицирует его.
public enum ZipCentralDirectory {

    /// Сколько байт с конца файла просматривать в поисках сигнатуры конца
    /// каталога. Комментарий архива ограничен 65 535 байтами, плюс сама запись:
    /// в этом окне сигнатура есть всегда, если она вообще есть.
    private static let tailWindow = 66_000

    /// Верхний предел записей по умолчанию — защита памяти, а не скорости:
    /// 10 000 имён разбираются за десятки миллисекунд, но архив с миллионом
    /// записей вырастет в сотни мегабайт строк.
    public static let defaultLimit = 100_000

    /// Имена записей архива. Папки (имена, оканчивающиеся на «/») отбрасываются:
    /// в выдаче поиска они шум — пользователь ищет файл.
    public static func entryNames(of archive: URL, limit: Int = defaultLimit) throws -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { throw ZipReadError.unreadable }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let tailStart = max(0, size - tailWindow)
        try? handle.seek(toOffset: UInt64(tailStart))
        guard let tail = try? handle.readToEnd(), !tail.isEmpty || size == 0 else {
            throw ZipReadError.unreadable
        }

        guard let endOffset = lastIndex(of: Self.endSignature, in: tail) else {
            throw ZipReadError.notAZipArchive
        }

        let end = try readEndRecord(tail, at: endOffset, tailStart: tailStart, handle: handle)
        guard end.entryCount > 0 else { return [] }

        let directory = try readDirectory(end, tail: tail, tailStart: tailStart, handle: handle)
        return parse(directory, entryCount: end.entryCount, limit: limit)
    }

    // MARK: - Конец центрального каталога

    private static let endSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let zip64LocatorSignature: [UInt8] = [0x50, 0x4B, 0x06, 0x07]
    private static let zip64EndSignature: [UInt8] = [0x50, 0x4B, 0x06, 0x06]
    private static let entrySignature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]

    private struct EndRecord {
        var entryCount: Int
        var directoryOffset: Int
        var directorySize: Int
    }

    /// Разбирает запись конца каталога, при необходимости уходя в Zip64.
    private static func readEndRecord(
        _ tail: Data, at offset: Int, tailStart: Int, handle: FileHandle
    ) throws -> EndRecord {
        let base = tail.startIndex + offset
        var record = EndRecord(
            entryCount: Int(readUInt16(tail, base + 10)),
            directoryOffset: Int(readUInt32(tail, base + 16)),
            directorySize: Int(readUInt32(tail, base + 12))
        )

        // Маркеры Zip64: 0xFFFF/0xFFFFFFFF означают «настоящее значение в
        // записи Zip64». Без этой ветки архив свыше 4 ГБ или с более чем 65 535
        // записями отдал бы обрезанный список — молча и неправильно.
        let needsZip64 = record.entryCount == 0xFFFF
            || record.directoryOffset == 0xFFFF_FFFF
            || record.directorySize == 0xFFFF_FFFF
        guard needsZip64 else { return record }

        guard let locator = lastIndex(of: zip64LocatorSignature, in: tail) else { return record }
        let zip64Offset = Int(readUInt64(tail, tail.startIndex + locator + 8))
        guard let zip64 = try readChunk(handle, at: zip64Offset, length: 56, tail: tail, tailStart: tailStart),
              Array(zip64.prefix(4)) == zip64EndSignature
        else { return record }

        record.entryCount = Int(readUInt64(zip64, zip64.startIndex + 32))
        record.directorySize = Int(readUInt64(zip64, zip64.startIndex + 40))
        record.directoryOffset = Int(readUInt64(zip64, zip64.startIndex + 48))
        return record
    }

    /// Возвращает байты центрального каталога — из уже прочитанного хвоста,
    /// если он туда попал, иначе отдельным чтением.
    private static func readDirectory(
        _ end: EndRecord, tail: Data, tailStart: Int, handle: FileHandle
    ) throws -> Data {
        guard let chunk = try readChunk(
            handle, at: end.directoryOffset, length: end.directorySize, tail: tail, tailStart: tailStart
        ) else { throw ZipReadError.notAZipArchive }
        return chunk
    }

    /// Читает участок файла, переиспользуя хвост: у большинства архивов каталог
    /// уже вычитан, и второе обращение к диску (по сети — к серверу) не нужно.
    private static func readChunk(
        _ handle: FileHandle, at offset: Int, length: Int, tail: Data, tailStart: Int
    ) throws -> Data? {
        guard offset >= 0, length >= 0 else { return nil }
        if offset >= tailStart {
            let start = tail.startIndex + (offset - tailStart)
            guard start <= tail.endIndex else { return nil }
            return tail[start..<min(tail.endIndex, start + length)]
        }
        try? handle.seek(toOffset: UInt64(offset))
        return try? handle.read(upToCount: length)
    }

    // MARK: - Записи каталога

    /// Проходит записи каталога и собирает имена.
    ///
    /// Останавливается на первой неопознанной сигнатуре, а не бросает ошибку:
    /// файл мог недокачаться по сети, и прочитанная часть всё равно полезнее
    /// пустого результата.
    private static func parse(_ directory: Data, entryCount: Int, limit: Int) -> [String] {
        var names: [String] = []
        names.reserveCapacity(min(entryCount, limit))

        var cursor = directory.startIndex
        while names.count < limit, cursor + 46 <= directory.endIndex {
            guard Array(directory[cursor..<(cursor + 4)]) == entrySignature else { break }

            let flags = readUInt16(directory, cursor + 8)
            let nameLength = Int(readUInt16(directory, cursor + 28))
            let extraLength = Int(readUInt16(directory, cursor + 30))
            let commentLength = Int(readUInt16(directory, cursor + 32))

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= directory.endIndex else { break }

            if nameLength > 0, let name = decodeName(directory[nameStart..<nameEnd], flags: flags),
               !name.hasSuffix("/") {
                names.append(name)
            }
            cursor = nameEnd + extraLength + commentLength
        }
        return names
    }

    /// Декодирует имя записи.
    ///
    /// Бит 11 общих флагов объявляет имя в UTF-8 — так пишут современные
    /// архиваторы. Без него спецификация предписывает CP437, и русские имена из
    /// архивов, собранных старым Windows-софтом, превратились бы в мусор.
    /// Практика, впрочем, богаче спецификации: многие архиваторы пишут UTF-8 без
    /// флага, поэтому сначала пробуем его в любом случае.
    private static func decodeName(_ bytes: Data, flags: UInt16) -> String? {
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        guard flags & 0x800 == 0 else { return nil }
        return String(data: bytes, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))))
    }

    // MARK: - Чтение чисел

    private static func lastIndex(of signature: [UInt8], in data: Data) -> Int? {
        guard data.count >= signature.count else { return nil }
        let bytes = [UInt8](data)
        var index = bytes.count - signature.count
        while index >= 0 {
            if Array(bytes[index..<(index + signature.count)]) == signature { return index }
            index -= 1
        }
        return nil
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.endIndex else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.endIndex else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << (8 * UInt32($1))) }
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.endIndex else { return 0 }
        return (0..<8).reduce(UInt64(0)) { $0 | (UInt64(data[offset + $1]) << (8 * UInt64($1))) }
    }
}
