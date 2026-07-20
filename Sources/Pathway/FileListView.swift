import AppKit
import PathwayCore
import SwiftUI
import UniformTypeIdentifiers

/// Список файлов. Обёртка над NSTableView: держит тысячи строк, даёт нативные
/// сортировку по заголовкам, инлайн-переименование, контекстное меню и drag & drop.
struct FileListView: NSViewRepresentable {
    let model: BrowserModel
    @Binding var renamingItem: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, renamingItem: $renamingItem)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 24
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.menu = context.coordinator.makeContextMenu()
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            table.addTableColumn(tableColumn)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        context.coordinator.table = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.table?.reloadData()
        context.coordinator.syncSelection()
        context.coordinator.beginRenamingIfNeeded()
    }

    enum Column: String, CaseIterable {
        case name, modified, size, kind

        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
        var title: String {
            switch self {
            case .name: "Имя"
            case .modified: "Дата изменения"
            case .size: "Размер"
            case .kind: "Тип"
            }
        }
        var width: CGFloat {
            switch self {
            case .name: 280
            case .modified: 160
            case .size: 90
            case .kind: 120
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var model: BrowserModel
        weak var table: NSTableView?
        @Binding var renamingItem: URL?
        private var isSyncingSelection = false

        init(model: BrowserModel, renamingItem: Binding<URL?>) {
            self.model = model
            self._renamingItem = renamingItem
        }

        // MARK: - Данные

        func numberOfRows(in tableView: NSTableView) -> Int {
            model.items.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }),
                  row < model.items.count
            else { return nil }
            let item = model.items[row]

            let cell = NSTableCellView()
            let text = NSTextField(labelWithString: model.text(for: item, column: column.rawValue))
            text.lineBreakMode = .byTruncatingTail
            text.delegate = self
            text.isEditable = column == .name
            text.isBordered = false
            text.drawsBackground = false
            text.alignment = column == .size ? .right : .left
            if column != .name {
                text.textColor = .secondaryLabelColor
            }
            cell.textField = text
            cell.addSubview(text)
            text.translatesAutoresizingMaskIntoConstraints = false

            var leading: NSLayoutXAxisAnchor = cell.leadingAnchor
            if column == .name {
                let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: item.url.path))
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                cell.imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16),
                ])
                leading = icon.trailingAnchor
            }
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: leading, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            // Вырезанные файлы выглядят полупрозрачными, как в проводнике Windows.
            cell.alphaValue = model.pane.isCut(item.url) ? 0.5 : 1.0
            return cell
        }

        // MARK: - Выделение и открытие

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let table else { return }
            model.pane.selection = Set(table.selectedRowIndexes.compactMap { row in
                row < model.items.count ? model.items[row].url : nil
            })
        }

        func syncSelection() {
            guard let table else { return }
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            let indexes = IndexSet(model.items.indices.filter { model.pane.selection.contains(model.items[$0].url) })
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }

        @objc func handleDoubleClick() {
            guard let table, table.clickedRow >= 0, table.clickedRow < model.items.count else { return }
            model.open(model.items[table.clickedRow])
        }

        // MARK: - Сортировка

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            model.sort(by: key, ascending: descriptor.ascending)
            tableView.reloadData()
        }

        // MARK: - Переименование

        func beginRenamingIfNeeded() {
            guard let renaming = renamingItem,
                  let table,
                  let row = model.items.firstIndex(where: { $0.url == renaming }),
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField
            else { return }
            table.window?.makeFirstResponder(field)
            selectNameWithoutExtension(in: field, item: model.items[row])
        }

        /// При переименовании выделяется только имя без расширения — как в проводнике.
        private func selectNameWithoutExtension(in field: NSTextField, item: FileItem) {
            guard !item.isDirectory else { return }
            let stem = item.url.deletingPathExtension().lastPathComponent
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: stem.count)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let renaming = renamingItem
            else { return }
            defer { renamingItem = nil }
            let newName = field.stringValue
            guard newName != renaming.lastPathComponent else { return }
            model.rename(renaming, to: newName)
        }

        // MARK: - Drag & drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard row < model.items.count else { return nil }
            return model.items[row].url as NSURL
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation operation: NSTableView.DropOperation
        ) -> NSDragOperation {
            // Бросать можно только на папку.
            guard operation == .on, row < model.items.count, model.items[row].isDirectory else { return [] }
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard row < model.items.count, model.items[row].isDirectory else { return false }
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
                  !urls.isEmpty
            else { return false }

            let destination = model.items[row].url
            if info.draggingSourceOperationMask.contains(.move) {
                model.move(urls, to: destination)
            } else {
                model.copy(urls, to: destination)
            }
            return true
        }

        // MARK: - Контекстное меню

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            let entries: [(String, Selector)] = [
                ("Открыть", #selector(menuOpen)),
                ("", #selector(menuOpen)),
                ("Копировать", #selector(menuCopy)),
                ("Вырезать", #selector(menuCut)),
                ("Вставить", #selector(menuPaste)),
                ("", #selector(menuOpen)),
                ("Переименовать", #selector(menuRename)),
                ("Новая папка", #selector(menuNewFolder)),
                ("", #selector(menuOpen)),
                ("Показать в Finder", #selector(menuRevealInFinder)),
                ("", #selector(menuOpen)),
                ("Переместить в Корзину", #selector(menuMoveToTrash)),
            ]
            for (title, action) in entries {
                if title.isEmpty {
                    menu.addItem(.separator())
                } else {
                    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                }
            }
            return menu
        }

        private var clickedItem: FileItem? {
            guard let table, table.clickedRow >= 0, table.clickedRow < model.items.count else { return nil }
            return model.items[table.clickedRow]
        }

        @objc private func menuOpen() { clickedItem.map { model.open($0) } }
        @objc private func menuCopy() { model.copy() }
        @objc private func menuCut() { model.cut() }
        @objc private func menuPaste() { model.paste() }
        @objc private func menuNewFolder() { model.createFolder() }
        @objc private func menuMoveToTrash() { model.moveSelectionToTrash() }
        @objc private func menuRename() { renamingItem = clickedItem?.url }
        @objc private func menuRevealInFinder() {
            guard let item = clickedItem else { return }
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
    }
}
