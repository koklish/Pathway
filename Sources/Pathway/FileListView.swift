import AppKit
import PathwayCore
import SwiftUI
import UniformTypeIdentifiers

/// Таблица, принимающая стандартные буферные команды.
///
/// Пункты «Копировать»/«Вставить»/«Выбрать всё» в меню «Правка» системные:
/// у них target = nil, и AppKit ищет обработчик по responder chain. Пока
/// фокус в списке, обработчик — эта таблица; как только он уходит в
/// текстовое поле, те же клавиши достаются полю. Один ⌘C работает в обоих
/// местах, как в Finder.
///
/// Методы живут в NSTableView, а не в координаторе: делегата в responder
/// chain нет, и до него сообщение не дошло бы.
final class FileTableView: NSTableView {
    /// Замыкания вместо ссылки на модель: PathwayCore не знает про AppKit,
    /// а таблица не должна знать про BrowserModel.
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var canPaste: (() -> Bool)?

    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func cut(_ sender: Any?) { onCut?() }
    @objc func paste(_ sender: Any?) { onPaste?() }
    override func selectAll(_ sender: Any?) { onSelectAll?() }

    /// Гасит пункты меню, когда действие невозможно: без этого «Вставить»
    /// остаётся активным при пустом буфере, а «Копировать» — без выделения.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return !selectedRowIndexes.isEmpty
        case #selector(paste(_:)):
            return canPaste?() ?? false
        case #selector(selectAll(_:)):
            return numberOfRows > 0
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

/// Список файлов. Обёртка над NSTableView: держит тысячи строк, даёт нативные
/// сортировку по заголовкам, инлайн-переименование, контекстное меню и drag & drop.
struct FileListView: NSViewRepresentable {
    let model: BrowserModel
    let actions: FolderActions
    let appState: AppState
    @Binding var renamingItem: URL?
    /// Открывает диалог архивации для выбранных элементов.
    let onCompress: ([FileItem]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model, actions: actions, appState: appState,
            renamingItem: $renamingItem, onCompress: onCompress
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
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

        // Буферные операции идут в ту же модель, что и контекстное меню, но
        // приходят сюда от системных пунктов «Правки» через responder chain.
        table.onCopy = { [model] in model.copy() }
        table.onCut = { [model] in model.cut() }
        table.onPaste = { [model] in model.paste() }
        table.onSelectAll = { [model] in model.selectAll() }
        table.canPaste = { [model] in model.canPaste && !model.isReadOnlyVolume }

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
        context.coordinator.appState = appState
        // Биндинг переприсваиваем на каждом обновлении: координатор создаётся один
        // раз и иначе навсегда сохранил бы биндинг от первого рендера, запись в
        // который не доходит до @State и не вызывает перерисовку.
        context.coordinator.rebind(renamingItem: $renamingItem)
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

            // Не labelWithString: label не берёт фокус, и makeFirstResponder при
            // переименовании молча возвращает false. Внешне поле остаётся плоским.
            let text = NSTextField()
            text.isEditable = false
            text.isSelectable = true
            text.lineBreakMode = .byTruncatingTail
            text.isBordered = false
            text.isBezeled = false
            text.focusRingType = .none
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
        var appState: AppState
        weak var table: NSTableView?
        @Binding var renamingItem: URL?
        let onCompress: ([FileItem]) -> Void
        private var isSyncingSelection = false
        /// Элемент, для которого редактор уже открыт: не даёт перезапускать правку.
        private var editingItem: URL?
        /// Имя до правки — для отката по Escape.
        private var originalName: String?
        /// Отмена по Escape тоже шлёт controlTextDidEndEditing; флаг гасит применение.
        private var isCancelling = false
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

        init(
            model: BrowserModel,
            actions: FolderActions,
            appState: AppState,
            renamingItem: Binding<URL?>,
            onCompress: @escaping ([FileItem]) -> Void
        ) {
            self.model = model
            self.actions = actions
            self.appState = appState
            self._renamingItem = renamingItem
            self.onCompress = onCompress
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

        /// SwiftUI зовёт updateNSView на любое изменение модели, поэтому редактирование
        /// запускается один раз на элемент: иначе повторный makeFirstResponder сбивал бы
        /// курсор и выделение посреди набора имени.
        func beginRenamingIfNeeded() {
            guard let renaming = renamingItem, renaming != editingItem, let table else { return }
            guard let row = model.items.firstIndex(where: { $0.url == renaming }) else { return }
            table.scrollRowToVisible(row)
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField
            else { return }
            editingItem = renaming
            originalName = renaming.lastPathComponent
            field.isEditable = true
            guard table.window?.makeFirstResponder(field) == true else {
                // Фокус не отдали — не оставляем поле в редактируемом состоянии.
                field.isEditable = false
                editingItem = nil
                renamingItem = nil
                return
            }
            // Пока идёт набор имени, F2 и ⌘⌫ не должны срабатывать как файловые
            // команды: текстовое поле их не перехватывает, в отличие от ⌘C/⌘V.
            appState.isEditingText = true
            selectNameWithoutExtension(in: field, item: model.items[row])
        }

        /// Координатор живёт дольше структуры FileListView, поэтому биндинг нужно
        /// обновлять: сохранённый от первого рендера ведёт в отработавший экземпляр,
        /// и запись в него не доходит до @State владельца.
        func rebind(renamingItem: Binding<URL?>) {
            self._renamingItem = renamingItem
        }

        /// Возвращает поле в состояние обычной подписи после конца редактирования.
        /// Вызывается на всех путях завершения — Enter, Escape, потеря фокуса, —
        /// поэтому здесь же снимается флаг ввода текста.
        private func finishEditing(_ field: NSTextField) {
            field.isEditable = false
            editingItem = nil
            originalName = nil
            appState.isEditingText = false
        }

        /// При переименовании выделяется только имя без расширения — как в проводнике.
        private func selectNameWithoutExtension(in field: NSTextField, item: FileItem) {
            guard !item.isDirectory else { return }
            let stem = item.url.deletingPathExtension().lastPathComponent
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: stem.count)
        }

        /// Escape отменяет правку: возвращаем исходное имя и снимаем фокус,
        /// иначе NSTextField завершил бы ввод и имя применилось бы.
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  let field = control as? NSTextField,
                  let original = originalName
            else { return false }
            isCancelling = true
            field.stringValue = original
            renamingItem = nil
            finishEditing(field)
            table?.window?.makeFirstResponder(table)
            isCancelling = false
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, !isCancelling else { return }
            guard let renaming = renamingItem else {
                finishEditing(field)
                return
            }
            let newName = field.stringValue
            renamingItem = nil
            finishEditing(field)
            guard !newName.isEmpty, newName != renaming.lastPathComponent else {
                // Пустое или неизменённое имя — откатываем текст ячейки.
                field.stringValue = renaming.lastPathComponent
                return
            }
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
                add(to: menu, .open, #selector(menuOpen))
                menu.addItem(.separator())
            }

            add(to: menu, .copy, #selector(menuCopy))
            add(to: menu, .cut, #selector(menuCut))
            add(to: menu, .paste, #selector(menuPaste))
            menu.addItem(.separator())

            if item != nil {
                add(to: menu, .rename, #selector(menuRename))
            }
            add(to: menu, .newFolder, #selector(menuNewFolder))
            menu.addItem(.separator())

            // Архивы: одна операция за раз, во время неё пункты неактивны
            // (пункт без action система выключает сама).
            if let item {
                let busy = model.isBusy
                if !item.isDirectory && ArchiveService.isArchive(item.url) {
                    add(to: menu, .extractHere, busy ? nil : #selector(menuExtractHere))
                    add(to: menu, .extractHere, busy ? nil : #selector(menuExtractTo), title: "Распаковать в…")
                } else {
                    let targets = archiveTargets
                    let title = targets.count > 1 ? "Архивировать \(targets.count) объектов…" : nil
                    add(to: menu, .compress, busy ? nil : #selector(menuCompress), title: title)
                }
                menu.addItem(.separator())
            }

            // Терминал открывается в кликнутой папке, а для файла или пустого
            // места — в текущей: пункт всегда осмыслен.
            add(to: menu, .openTerminal, #selector(menuOpenTerminal))
            if actions.isClaudeAvailable {
                add(to: menu, .openClaude, #selector(menuOpenClaude))
            }
            menu.addItem(.separator())

            let isFavorite = actions.isFavorite(folder)
            add(to: menu, .toggleFavorite, #selector(menuToggleFavorite),
                title: isFavorite ? "Убрать из избранного" : "Добавить в избранное",
                icon: MenuIcon.symbol(isFavorite ? "star.slash" : "star", .systemYellow))
            add(to: menu, .revealInFinder, #selector(menuRevealInFinder))

            if item != nil {
                menu.addItem(.separator())
                add(to: menu, .moveToTrash, #selector(menuMoveToTrash))
            }
        }

        /// Пункт контекстного меню из реестра команд: заголовок, иконка и
        /// показанный шорткат берутся оттуда же, откуда их берёт главное меню,
        /// поэтому разъехаться они не могут.
        ///
        /// Действие остаётся своим: контекстное меню работает от кликнутой
        /// строки, а не от выделения, — это нативное поведение macOS.
        private func add(
            to menu: NSMenu,
            _ id: CommandID,
            _ action: Selector?,
            title: String? = nil,
            icon: NSImage? = nil
        ) {
            let command = CommandRegistry[id]
            // На томе только для чтения пункт остаётся видимым, но мёртвым:
            // без action система гасит его сама. Контекст исполнения у
            // контекстного меню свой (clickedRow), а вот запрет на запись
            // общий, и брать его надо из реестра.
            let writable = !model.isReadOnlyVolume || !CommandRegistry.writesToDisk.contains(id)
            // У буферных команд своего шортката в реестре нет — он системный,
            // и показать его надо всё равно: пункт без подписи выглядит так,
            // будто клавиши для него не существует.
            let shortcut = command.shortcut ?? Self.systemShortcut(for: id)
            let item = NSMenuItem(
                title: title ?? command.title,
                action: writable ? action : nil,
                keyEquivalent: shortcut?.appKitKey ?? ""
            )
            item.keyEquivalentModifierMask = shortcut?.appKitModifiers ?? []
            item.target = self
            item.image = icon ?? command.menuImage
            menu.addItem(item)
        }

        /// Клавиши буферных команд принадлежат меню «Правка», а не реестру:
        /// там они лежат без шортката, чтобы не перехватывать его у
        /// текстовых полей. Для подписи в контекстном меню соответствие
        /// нужно восстановить.
        private static func systemShortcut(for id: CommandID) -> Shortcut? {
            switch id {
            case .copy: Shortcut(.character("c"), .command)
            case .cut: Shortcut(.character("x"), .command)
            case .paste: Shortcut(.character("v"), .command)
            case .selectAll: Shortcut(.character("a"), .command)
            default: nil
            }
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

        /// Элементы, которые попадут в архив: вся мультиселекция, если клик был
        /// по ней, иначе только кликнутый элемент.
        private var archiveTargets: [FileItem] {
            guard let item = clickedItem else { return [] }
            let selected = model.items.filter { model.pane.selection.contains($0.url) }
            if selected.count > 1, selected.contains(where: { $0.url == item.url }) {
                return selected
            }
            return [item]
        }

        @objc private func menuCompress() {
            let targets = archiveTargets
            guard !targets.isEmpty else { return }
            onCompress(targets)
        }

        @objc private func menuExtractHere() {
            clickedItem.map { model.extract($0) }
        }

        @objc private func menuExtractTo() {
            guard let item = clickedItem else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Распаковать"
            panel.message = "Куда распаковать «\(item.name)»"
            panel.directoryURL = model.pane.path
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            model.extract(item, to: destination)
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
