import AppKit
import PathwayCore
import UniformTypeIdentifiers

/// Иконки файлов для списка.
///
/// `NSWorkspace.icon(forFile:)` обращается к диску на каждый вызов — 3.1 мс на строку,
/// то есть 125 мс на экран при скролле. Иконка по типу файла стоит 0.003 мс и для списка
/// неотличима, поэтому берём её и кэшируем по расширению.
@MainActor
enum IconCache {
    /// Размер иконки вне списка файлов: полоса вкладок и результаты поиска
    /// масштаб не разделяют и остаются на нём всегда.
    static let fixedSize: CGFloat = 16

    /// Ключ — расширение вместе с размером: `NSImage.size` меняет сам объект,
    /// и общая на все размеры запись отдавала бы растянутый растр от прошлой
    /// ступени всем, кто попросил иконку до смены масштаба.
    private struct Key: Hashable {
        let ext: String
        let size: CGFloat
    }

    private static var byExtension: [Key: NSImage] = [:]
    private static var folderIcons: [CGFloat: NSImage] = [:]

    /// Иконка папки. Нужна полосе вкладок, где элемент — путь, а не FileItem.
    static var folder: NSImage { folder(size: fixedSize) }

    static func folder(size: CGFloat) -> NSImage {
        if let cached = folderIcons[size] { return cached }
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: size, height: size)
        folderIcons[size] = icon
        return icon
    }

    /// Размер по умолчанию — для вызывающих вне списка файлов: им масштаб не
    /// нужен, и параметр каждый раз указывать не приходится.
    static func icon(for item: FileItem, size: CGFloat = fixedSize) -> NSImage {
        if item.isDirectory {
            return folder(size: size)
        }

        let key = Key(ext: item.url.pathExtension.lowercased(), size: size)
        if let cached = byExtension[key] { return cached }

        let type = UTType(filenameExtension: key.ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: size, height: size)
        byExtension[key] = icon
        return icon
    }
}
