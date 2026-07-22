import AppKit
import PathwayCore
import SwiftUI
import UniformTypeIdentifiers

/// Список файлов. Обёртка над NSTableView: держит тысячи строк, даёт нативные
/// сортировку по заголовкам, инлайн-переименование, контекстное меню и drag & drop.
struct FileListView: NSViewRepresentable {
    let model: BrowserModel
    let actions: FolderActions
    @Binding var renamingItem: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, actions: actions, renamingItem: $renamingItem)
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
        // Меню пересобирается при каждом открытии: состав пунктов зависит от того,
        // по чему кликнули и лежит ли папка в избранном.
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
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
        context.coordinator.actions = actions
        context.coordinator.reloadIfContentChanged()
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

    /// Ячейка списка с ручной раскладкой.
    ///
    /// Auto Layout здесь стоил 1.4 мс на ячейку — 56 мс на экран при скролле.
    /// Раскладка тривиальная (иконка слева, текст на всю оставшуюся ширину),
    /// поэтому считаем рамки сами.
    final class FileCell: NSTableCellView {
        private let showsIcon: Bool

        init(identifier: NSUserInterfaceItemIdentifier, showsIcon: Bool) {
            self.showsIcon = showsIcon
            super.init(frame: .zero)
            self.identifier = identifier

            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.isBordered = false
            text.drawsBackground = false
            addSubview(text)
            textField = text

            if showsIcon {
                let icon = NSImageView()
                icon.imageScaling = .scaleProportionallyDown
                addSubview(icon)
                imageView = icon
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

        override func layout() {
            super.layout()
            var textLeft: CGFloat = 4
            if showsIcon, let icon = imageView {
                icon.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: 16, height: 16)
                textLeft = icon.frame.maxX + 6
            }
            textField?.frame = NSRect(
                x: textLeft,
                y: (bounds.height - 17) / 2,
                width: max(0, bounds.width - textLeft - 4),
                height: 17
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var model: BrowserModel
        var actions: FolderActions
        weak var table: NSTableView?
        @Binding var renamingItem: URL?
        private var isSyncingSelection = false
        /// Слепок показанного списка: перерисовываем только когда он реально изменился.
        /// Флаг metadataLoaded здесь обязателен — иначе догрузка размеров и дат
        /// не доедет до экрана, ведь состав списка при ней не меняется.
        private var renderedSignature: [SignatureEntry] = []

        struct SignatureEntry: Equatable {
            let url: URL
            let metadataLoaded: Bool
        }

        /// SwiftUI дёргает updateNSView на любое изменение модели, включая выделение.
        /// Полный reloadData сбрасывает ячейки и рвёт скролл, поэтому делаем его
        /// только когда содержимое действительно изменилось.
        func reloadIfContentChanged() {
            let signature = model.items.map { SignatureEntry(url: $0.url, metadataLoaded: $0.metadataLoaded) }
            guard signature != renderedSignature else { return }
            renderedSignature = signature
            table?.reloadData()
        }

        init(model: BrowserModel, actions: FolderActions, renamingItem: Binding<URL?>) {
            self.model = model
            self.actions = actions
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

            // Переиспользуем ячейку: создание с нуля стоит 1.4 мс, а на экране их сорок.
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? FileCell
                ?? FileCell(identifier: column.identifier, showsIcon: column == .name)

            cell.textField?.stringValue = model.text(for: item, column: column.rawValue)
            cell.textField?.delegate = self
            cell.textField?.isEditable = column == .name
            cell.textField?.alignment = column == .size ? .right : .left
            cell.textField?.textColor = column == .name ? .labelColor : .secondaryLabelColor

            if column == .name {
                cell.imageView?.image = IconCache.icon(for: item)
            }

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
            guard let destination = dropDestination(info, row: row, operation: operation) else { return [] }
            // Бросок на пустое место списка перерисовываем как «в текущую папку»,
            // иначе AppKit подсветит промежуток между строками и обещание не совпадёт с делом.
            if destination == model.pane.path {
                tableView.setDropRow(-1, dropOperation: .on)
            }
            return dragOperation(for: info, destination: destination)
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let destination = dropDestination(info, row: row, operation: dropOperation) else { return false }
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
                  !urls.isEmpty
            else { return false }

            if dragOperation(for: info, destination: destination) == .move {
                model.move(urls, to: destination)
            } else {
                model.copy(urls, to: destination)
            }
            return true
        }

        /// Папка, в которую упадут файлы: строка-папка под курсором либо, при броске
        /// на пустое место, текущая открытая папка.
        private func dropDestination(
            _ info: any NSDraggingInfo,
            row: Int,
            operation: NSTableView.DropOperation
        ) -> URL? {
            DropTargeting.destination(
                row: row,
                isOnRow: operation == .on,
                isLocalDrag: isLocalDrag(info),
                itemAt: { index in
                    guard index < model.items.count, model.items[index].isDirectory else { return nil }
                    return model.items[index].url
                },
                currentFolder: model.pane.path
            )
        }

        private func isLocalDrag(_ info: any NSDraggingInfo) -> Bool {
            (info.draggingSource as? NSTableView) === table
        }

        /// Копировать или переместить: внутри одного тома — перемещение, между
        /// томами — копирование, как в Finder. ⌥ форсирует копирование, ⌘ — перемещение.
        private func dragOperation(for info: any NSDraggingInfo, destination: URL) -> NSDragOperation {
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.option) { return .copy }
            if modifiers.contains(.command) { return .move }

            let allowed = info.draggingSourceOperationMask
            guard allowed.contains(.move) else { return .copy }

            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
            guard let source = urls?.first else { return .copy }
            return sameVolume(source, destination) ? .move : .copy
        }

        private func sameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
            let key: URLResourceKey = .volumeIdentifierKey
            let left = (try? lhs.resourceValues(forKeys: [key]))?.volumeIdentifier
            let right = (try? rhs.resourceValues(forKeys: [key]))?.volumeIdentifier
            guard let left, let right else { return false }
            return left.isEqual(right)
        }

        /// После перемещения файла наружу строка осталась бы висеть до следующего
        /// обновления — папку нужно перечитать.
        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            guard operation == .move || operation == .delete else { return }
            model.reloadAsync()
        }

        // MARK: - Контекстное меню

        /// Меню собирается заново на каждое открытие: подпись пункта избранного
        /// зависит от того, закреплена ли папка, а состав — от того, по чему кликнули.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let item = clickedItem
            let folder = terminalTarget

            if item != nil {
                add(to: menu, "Открыть", #selector(menuOpen))
                menu.addItem(.separator())
            }

            add(to: menu, "Копировать", #selector(menuCopy))
            add(to: menu, "Вырезать", #selector(menuCut))
            add(to: menu, "Вставить", #selector(menuPaste))
            menu.addItem(.separator())

            if item != nil {
                add(to: menu, "Переименовать", #selector(menuRename))
            }
            add(to: menu, "Новая папка", #selector(menuNewFolder))
            menu.addItem(.separator())

            // Терминал открывается в кликнутой папке, а для файла или пустого
            // места — в текущей: пункт всегда осмыслен.
            add(to: menu, "Открыть в Терминале", #selector(menuOpenTerminal))
            if actions.isClaudeAvailable {
                add(to: menu, "Открыть в Claude Code", #selector(menuOpenClaude))
            }
            menu.addItem(.separator())

            let title = actions.isFavorite(folder) ? "Убрать из избранного" : "Добавить в избранное"
            add(to: menu, title, #selector(menuToggleFavorite))
            add(to: menu, "Показать в Finder", #selector(menuRevealInFinder))

            if item != nil {
                menu.addItem(.separator())
                add(to: menu, "Переместить в Корзину", #selector(menuMoveToTrash))
            }
        }

        private func add(to menu: NSMenu, _ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        private var clickedItem: FileItem? {
            guard let table, table.clickedRow >= 0, table.clickedRow < model.items.count else { return nil }
            return model.items[table.clickedRow]
        }

        /// Папка, к которой относятся действия меню: кликнутая — если это папка,
        /// иначе текущая открытая.
        private var terminalTarget: URL {
            guard let item = clickedItem, item.isDirectory else { return model.pane.path }
            return item.url
        }

        @objc private func menuOpen() { clickedItem.map { model.open($0) } }
        @objc private func menuCopy() { model.copy() }
        @objc private func menuCut() { model.cut() }
        @objc private func menuPaste() { model.paste() }
        @objc private func menuNewFolder() { model.createFolder() }
        @objc private func menuMoveToTrash() { model.moveSelectionToTrash() }
        @objc private func menuRename() { renamingItem = clickedItem?.url }
        @objc private func menuOpenTerminal() { actions.openTerminal(at: terminalTarget) }
        @objc private func menuOpenClaude() { actions.openClaude(at: terminalTarget) }
        @objc private func menuToggleFavorite() { actions.toggleFavorite(terminalTarget) }
        @objc private func menuRevealInFinder() {
            // Кликнутый файл показываем выделенным, иначе открываем текущую папку.
            actions.revealInFinder(clickedItem?.url ?? model.pane.path)
        }
    }
}
