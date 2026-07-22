import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Свой тип для перестановки пунктов избранного. Отдельный от fileURL:
    /// иначе перетаскивание строки внутри секции было бы неотличимо от
    /// броска обычной папки, и вместо перестановки случилось бы перемещение файлов.
    static let pathwayFavorite = UTType(exportedAs: "app.pathway.favorite")
}

/// Пункт избранного, перетаскиваемый внутри сайдбара.
struct FavoriteTransfer: Codable, Transferable {
    let id: String
    /// Путь нужен, если пункт бросят наружу — в список файлов или в другое приложение.
    let path: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pathwayFavorite)
    }
}

/// Содержимое перетаскивания: либо переставляемый пункт избранного, либо файлы.
///
/// Один тип на оба случая нужен потому, что строка избранного принимает и то,
/// и другое, а решение зависит от того, что именно принесли.
enum DroppedItem: Transferable {
    case favorite(FavoriteTransfer)
    case url(URL)

    var favorite: FavoriteTransfer? {
        if case let .favorite(transfer) = self { return transfer }
        return nil
    }

    var url: URL? {
        if case let .url(url) = self { return url }
        return nil
    }

    static var transferRepresentation: some TransferRepresentation {
        // Порядок важен: свой тип проверяется первым, иначе перетаскивание
        // пункта избранного распозналось бы как обычный файловый URL.
        ProxyRepresentation { DroppedItem.favorite($0) }
        ProxyRepresentation { DroppedItem.url($0) }
    }
}
