import Foundation

/// Какой документ Office собрать. Каждому виду отвечает свой набор XML-частей.
public enum OOXMLKind: Sendable, Equatable {
    case word, excel, powerPoint
}

/// Собирает минимальный валидный документ OOXML прямо в памяти.
///
/// Документы Office — это ZIP-архивы с XML внутри, и пустой файл нулевой длины
/// таковым не является: `unzip` на нём сообщает «End-of-central-directory
/// signature not found», а Word ровно так же объявляет документ повреждённым.
/// Поэтому «просто создать файл с нужным расширением» годится для txt, но не
/// для форматов Office — им нужен настоящий контейнер.
///
/// Собирается он здесь, а не хранится заготовкой в ресурсах, потому что
/// ресурсный бандл может не доехать до собранного приложения: `Bundle.module`
/// в этом случае вызывает fatalError и роняет процесс при первом «Создать →
/// документ». Сгенерированному в коде содержимому нечему не доехать.
public enum OOXMLBuilder {
    /// Одна часть архива: путь внутри контейнера и его содержимое.
    private struct Part {
        let name: String
        let data: Data

        init(_ name: String, _ xml: String) {
            self.name = name
            self.data = Data(xml.utf8)
        }
    }

    public static func data(for kind: OOXMLKind) -> Data {
        zip(parts(for: kind))
    }

    // MARK: - Содержимое частей

    private static func parts(for kind: OOXMLKind) -> [Part] {
        switch kind {
        case .word: word
        case .excel: excel
        case .powerPoint: powerPoint
        }
    }

    private static let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

    /// Пространства имён намеренно записаны полностью: Word отвергает документ,
    /// в котором объявление префикса не совпадает со схемой дословно.
    private static var word: [Part] {
        [
            Part("[Content_Types].xml", """
            \(declaration)
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/word/document.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            </Types>
            """),
            Part("_rels/.rels", """
            \(declaration)
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
            Target="word/document.xml"/>\
            </Relationships>
            """),
            // Пустой абзац, а не пустое тело: Word показывает документ с курсором
            // в первой строке, как при создании документа им самим.
            Part("word/document.xml", """
            \(declaration)
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
            <w:body><w:p/></w:body></w:document>
            """),
        ]
    }

    private static var excel: [Part] {
        [
            Part("[Content_Types].xml", """
            \(declaration)
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            </Types>
            """),
            Part("_rels/.rels", """
            \(declaration)
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
            Target="xl/workbook.xml"/>\
            </Relationships>
            """),
            Part("xl/workbook.xml", """
            \(declaration)
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets><sheet name="Лист1" sheetId="1" r:id="rId1"/></sheets></workbook>
            """),
            // Связи книги лежат в _rels рядом с ней: путь к листу Excel ищет
            // именно здесь, а не в корневом _rels/.rels.
            Part("xl/_rels/workbook.xml.rels", """
            \(declaration)
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
            Target="worksheets/sheet1.xml"/>\
            </Relationships>
            """),
            Part("xl/worksheets/sheet1.xml", """
            \(declaration)
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <sheetData/></worksheet>
            """),
        ]
    }

    private static var powerPoint: [Part] {
        [
            Part("[Content_Types].xml", """
            \(declaration)
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/ppt/presentation.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
            <Override PartName="/ppt/slides/slide1.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>\
            <Override PartName="/ppt/slideLayouts/slideLayout1.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
            <Override PartName="/ppt/slideMasters/slideMaster1.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
            </Types>
            """),
            Part("_rels/.rels", """
            \(declaration)
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
            Target="ppt/presentation.xml"/>\
            </Relationships>
            """),
            // Размер слайда обязателен: без sldSz PowerPoint не может разложить
            // слайд и считает презентацию повреждённой. 9144000×6858000 EMU —
            // это 10×7,5 дюйма, стандартный размер 4:3.
            Part("ppt/presentation.xml", """
            \(declaration)
            <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
            <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
            <p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>\
            <p:sldSz cx="9144000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/>\
            </p:presentation>
            """),
            Part("ppt/_rels/presentation.xml.rels", """
            \(declaration)
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" \
            Target="slideMasters/slideMaster1.xml"/>\
            <Relationship Id="rId2" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" \
            Target="slides/slide1.xml"/>\
            </Relationships>
            """),
            Part("ppt/slides/slide1.xml", """
            \(declaration)
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
            <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr/></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """),
            Part("ppt/slides/_rels/slide1.xml.rels", """
            \(declaration)
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" \
            Target="../slideLayouts/slideLayout1.xml"/>\
            </Relationships>
            """),
            Part("ppt/slideMasters/slideMaster1.xml", """
            \(declaration)
            <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
            <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr/></p:spTree></p:cSld>\
            <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" \
            accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" \
            folHlink="folHlink"/>\
            <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
            </p:sldMaster>
            """),
            Part("ppt/slideMasters/_rels/slideMaster1.xml.rels", """
            \(declaration)
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" \
            Target="../slideLayouts/slideLayout1.xml"/>\
            </Relationships>
            """),
            Part("ppt/slideLayouts/slideLayout1.xml", """
            \(declaration)
            <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank">\
            <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr/></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
            """),
            Part("ppt/slideLayouts/_rels/slideLayout1.xml.rels", """
            \(declaration)
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" \
            Target="../slideMasters/slideMaster1.xml"/>\
            </Relationships>
            """),
        ]
    }

    // MARK: - Сборка ZIP

    /// Пишет ZIP без сжатия (метод store).
    ///
    /// Своя реализация вместо библиотеки: части весят сотни байт, сжимать нечего,
    /// а формат store — это три структуры без битовой арифметики. Зависимость
    /// ради этого в таргете, не имеющем сегодня ни одной, обошлась бы дороже.
    private static func zip(_ parts: [Part]) -> Data {
        var archive = Data()
        var directory = Data()

        for part in parts {
            let name = Data(part.name.utf8)
            let crc = crc32(part.data)
            let offset = UInt32(archive.count)

            // Локальный заголовок: сигнатура, версия, флаги, метод, дата, CRC,
            // размеры, длины имени и дополнительного поля.
            archive.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            archive.append(uint16: 20)
            archive.append(uint16: 0)
            archive.append(uint16: 0)
            archive.append(uint16: 0)
            archive.append(uint16: 0)
            archive.append(uint32: crc)
            archive.append(uint32: UInt32(part.data.count))
            archive.append(uint32: UInt32(part.data.count))
            archive.append(uint16: UInt16(name.count))
            archive.append(uint16: 0)
            archive.append(name)
            archive.append(part.data)

            // Запись центрального каталога — та же информация плюс смещение
            // локального заголовка. Именно по каталогу распаковщик находит части.
            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            directory.append(uint16: 20)
            directory.append(uint16: 20)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint32: crc)
            directory.append(uint32: UInt32(part.data.count))
            directory.append(uint32: UInt32(part.data.count))
            directory.append(uint16: UInt16(name.count))
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint32: 0)
            directory.append(uint32: offset)
            directory.append(name)
        }

        let directoryOffset = UInt32(archive.count)
        archive.append(directory)

        // Хвост архива (EOCD) — то, чего нет у пустого файла и из-за чего
        // распаковщик объявляет его не ZIP-архивом.
        archive.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        archive.append(uint16: 0)
        archive.append(uint16: 0)
        archive.append(uint16: UInt16(parts.count))
        archive.append(uint16: UInt16(parts.count))
        archive.append(uint32: UInt32(directory.count))
        archive.append(uint32: directoryOffset)
        archive.append(uint16: 0)

        return archive
    }

    // MARK: - CRC32

    /// Таблица стандартного полинома 0xEDB88320. В Foundation CRC32 нет, а без
    /// него архив читается не всяким распаковщиком.
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Запись чисел

/// ZIP хранит числа от младшего байта к старшему — порядок задан форматом,
/// а не архитектурой машины, поэтому пишется явно.
private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
