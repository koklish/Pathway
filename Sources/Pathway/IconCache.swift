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
    private static var byExtension: [String: NSImage] = [:]
    private static var folderIcon: NSImage?

    static func icon(for item: FileItem) -> NSImage {
        if item.isDirectory {
            if let cached = folderIcon { return cached }
            let icon = NSWorkspace.shared.icon(for: .folder)
            icon.size = NSSize(width: 16, height: 16)
            folderIcon = icon
            return icon
        }

        let ext = item.url.pathExtension.lowercased()
        if let cached = byExtension[ext] { return cached }

        let type = UTType(filenameExtension: ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: 16, height: 16)
        byExtension[ext] = icon
        return icon
    }
}
