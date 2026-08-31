import AppKit
import PathwayCore
import QuickLookUI
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
    /// Средний клик по строке — открыть папку фоновой вкладкой.
    var onMiddleClick: ((Int) -> Void)?
    /// Файлы для быстрого просмотра — текущее выделение.
    ///
    /// Замыкание, а не сохранённый массив: список должен читаться в момент
    /// показа. Панель следует за выделением, пока открыта, и слепок,
    /// сделанный при первом нажатии, к следующей стрелке уже устарел бы.
    var previewItems: (() -> [URL])?

    /// Пробел открывает и закрывает панель быстрого просмотра, как в Finder.
    ///
    /// Клавиша обрабатывается здесь, а не шорткатом пункта меню: keyEquivalent
    /// перехватывал бы пробел глобально, и его нельзя было бы набрать в имени
    /// файла, адресной строке и поиске. Пока фокус в списке — пробел наш,
    /// как только уходит в текстовое поле — его.
    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            super.keyDown(with: event)
            return
        }
        toggleQuickLook()
    }

    /// Показывает панель или закрывает уже открытую.
    ///
    /// Открывать на пустом выделении нечего: панель показала бы пустоту с
    /// надписью, что файл не выбран.
    func toggleQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        guard previewItems?().isEmpty == false else { return }
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    /// Средний клик обрабатывает сама таблица, а не делегат: otherMouseUp до
    /// него не дойдёт — делегата нет в responder chain. Действие вешаем на
    /// отпускание, а не на нажатие: так ведут себя браузеры, и промах мимо
    /// строки при зажатой кнопке ничего не открывает.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        guard clicked >= 0 else { return }
        onMiddleClick?(clicked)
    }

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

// MARK: - Быстрый просмотр
//
// Панель ищет себе управляющего по responder chain: спрашивает у первого
// респондера acceptsPreviewPanelControl и ему же отдаёт себя. Первый
// респондер — таблица, поэтому и датасорс, и делегат живут здесь, а не в
// координаторе: его в responder chain нет, до него запрос не дошёл бы.
//
// QLPreviewPanelController в списке конформансов не значится: это неформальный
// протокол из категории NSObject, отдельного типа в Swift у него нет — панель
// проверяет наличие самих методов. Поэтому три метода ниже переопределяют
// заглушки NSResponder.
//
// @preconcurrency на конформансах обязателен: в SDK эти протоколы не
// изолированы, а FileTableView как наследник NSView живёт на главном акторе —
// Swift 6 считает такой конформанс гонкой. Панель зовёт их только с главного
// потока, поэтому изоляция здесь фактическая, а не заявленная в заголовке.
@MainActor
extension FileTableView: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // nonisolated обязателен: это override заглушек NSResponder, а они в SDK
    // не изолированы — ужесточить изоляцию в наследнике Swift не даёт.
    // Тело всё же трогает главноакторные свойства панели, поэтому изоляция
    // подтверждается через assumeIsolated: вызывает эти методы сама панель, и
    // только с главного потока.
    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems?().count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = previewItems?() ?? []
        // Индекс приходит от панели, а выделение могло смениться между её
        // запросом и нашим чтением: панель перерисовывается асинхронно.
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    /// Отдаёт панели клавиши, которые должны достаться списку.
    ///
    /// Пока панель открыта, она забирает ввод себе целиком. Без этого пробел
    /// её не закрывал бы (открыть — открывает, а обратно только Esc), а
    /// стрелки листали бы предпросмотр, не двигая выделение в списке.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        else { return false }

        if event.charactersIgnoringModifiers == " " {
            panel.orderOut(nil)
            return true
        }
        // Только вертикальные стрелки: выделение едет по списку, а панель
        // перерисовывается вслед за ним — так листают папку картинок.
        //
        // Перехватывать всё подряд нельзя: Esc должен закрывать панель, ⌘W —
        // окно, а ←/→ листают страницы внутри самого предпросмотра. Забрав их
        // себе, мы бы их погасили — таблице они не нужны.
        let vertical: Set<UInt16> = [125, 126] // стрелки вниз и вверх
        guard vertical.contains(event.keyCode) else { return false }
        keyDown(with: event)
        return true
    }

    /// Зумирует открытие и закрытие панели от строки таблицы, как в Finder.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = (item as? NSURL) as URL?,
              let index = previewItems?().firstIndex(of: url),
              let window
        else { return .zero }
        // Строка выделения в списке, а не в панели: индексы совпадают только
        // при выделении подряд, а зумить надо от того, что видно на экране.
        let row = selectedRowIndexes.sorted()
        guard index < row.count else { return .zero }
        let rect = rect(ofRow: row[index])
        guard !rect.isEmpty else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
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
        // Стартовая высота, дальше её ведёт applyScaleIfChanged: он же
        // выставит сохранённую ступень при первом updateNSView.
        table.rowHeight = appState.scale.rowHeight
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
        // Через координатор, а не через захваченный appState: он обновляется в
        // updateNSView и всегда указывает на актуальную вкладку.
        table.onMiddleClick = { [coordinator = context.coordinator] row in
            coordinator.openInBackgroundTab(row: row)
        }
        // Через координатор: model в замыкании застыла бы на первом рендере и
        // после смены вкладки показывала бы файлы прошлой.
        table.previewItems = { [coordinator = context.coordinator] in
            coordinator.model.selectedItems.map(\.url)
        }

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            // Умолчание AppKit — 10 pt: колонку можно утащить до нечитаемой
            // полоски, где не помещается даже значок.
            tableColumn.minWidth = 50
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.rawValue, ascending: !column.prefersDescending
            )
            table.addTableColumn(tableColumn)
        }

        // Стрелка в заголовке ставится по сохранённой сортировке: без этого
        // список был бы отсортирован по дате создания, а указатель стоял бы на
        // «Имени» — и первый клик по дате не менял бы ничего на вид.
        //
        // Присваивание массива само по себе не зовёт sortDescriptorsDidChange
        // (нотификация приходит только от клика по заголовку), поэтому лишней
        // записи сортировки в хранилище здесь не случается.
        table.sortDescriptors = [
            NSSortDescriptor(key: appState.sort.key, ascending: appState.sort.ascending)
        ]

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
        // До reloadIfContentChanged: перестроенные там ячейки должны сразу
        // получить новую высоту строки, иначе список моргнул бы дважды.
        context.coordinator.applyScaleIfChanged()
        context.coordinator.reloadIfContentChanged()
        context.coordinator.syncSelection()
        // После syncSelection: прокрутка ищет строку в уже синхронизированной
        // таблице, а выделение к этому моменту стоит.
        context.coordinator.revealIfNeeded()
        context.coordinator.beginRenamingIfNeeded()
        context.coordinator.showQuickLookIfNeeded()
        // Выделение могла сменить и сама модель — переходом к созданному файлу
        // или сменой вкладки. Открытая панель обязана показать то, что выделено
        // сейчас: tableViewSelectionDidChange на такие правки не приходит.
        context.coordinator.refreshQuickLook()
    }

    enum Column: String, CaseIterable {
        case name, modified, size, kind, branch

        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
        var title: String {
            switch self {
            case .name: "Имя"
            case .modified: "Дата изменения"
            case .size: "Размер"
            case .kind: "Тип"
            case .branch: "Ветка"
            }
        }
        var width: CGFloat {
            switch self {
            case .name: 280
            case .modified: 160
            case .size: 90
            case .kind: 120
            // Шире остальных: ветки вида feature/COMETP/1897 при 140 pt
            // обрезались по центру постоянно, а обрезка должна быть
            // исключением, а не нормой.
            case .branch: 180
            }
        }

        /// Направление, которое даст первый клик по заголовку.
        ///
        /// У даты — по убыванию: от колонки с датой ждут «свежие сверху», а
        /// NSTableView берёт направление первого клика именно из прототипа
        /// дескриптора, и с ascending: true первый клик показал бы самое старое.
        var prefersDescending: Bool {
            self == .modified
        }
    }

    /// Ячейка списка с ручной раскладкой.
    ///
    /// Auto Layout здесь стоил 1.4 мс на ячейку — 56 мс на экран при скролле.
    /// Раскладка тривиальная (иконка слева, текст на всю оставшуюся ширину),
    /// поэтому считаем рамки сами.
    final class FileCell: NSTableCellView {
        private let showsIcon: Bool

        /// Масштаб этой ячейки. Хранится в ней, а не читается из модели при
        /// раскладке: ячейки переиспользуются, и layout() зовётся при скролле
        /// — обращение к модели оттуда стоило бы на каждой строке.
        var scale: ListScale = .default {
            didSet {
                guard scale != oldValue else { return }
                textField?.font = .systemFont(ofSize: scale.fontSize)
                needsLayout = true
            }
        }

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
                let side = scale.iconSize
                icon.frame = NSRect(x: 4, y: (bounds.height - side) / 2, width: side, height: side)
                // Зазор растёт вместе с иконкой: постоянные 6 pt на огромной
                // ступени прижимали бы имя к значку вплотную.
                textLeft = icon.frame.maxX + max(6, side * 0.38)
            }
            // Высота поля от шрифта, а не константа: жёсткие 17 pt обрезали бы
            // выносные элементы кириллицы на крупных ступенях.
            let textHeight = ceil(scale.fontSize * 1.4)
            textField?.frame = NSRect(
                x: textLeft,
                y: (bounds.height - textHeight) / 2,
                width: max(0, bounds.width - textLeft - 4),
                height: textHeight
            )
        }
    }

    /// Ячейка колонки «Ветка»: держит чип и следит за подсветкой строки.
    ///
    /// Наследует NSTableCellView ради backgroundStyle — AppKit сообщает им о
    /// выделении строки, и без него синий чип на синем фоне исчезал бы.
    final class BranchChipCell: NSTableCellView {
        private let chip = BranchChipView()

        /// Чип идёт за именем файла: оставленный на прежнем кегле, на крупной
        /// ступени он выглядел бы приклеенным от прошлого масштаба.
        var scale: ListScale = .default {
            didSet {
                guard scale != oldValue else { return }
                chip.fontSize = scale.branchFontSize
                needsLayout = true
            }
        }

        var branch: String? {
            didSet {
                guard branch != oldValue else { return }
                chip.content = branch.map {
                    // Статус в списке не считается: он стоит git status на
                    // проект, а это до 21 мс на папку на сетевом томе.
                    BranchChipView.Content(branch: $0, isDetached: GitRepository.isDetached($0))
                }
                chip.isHidden = branch == nil
                needsLayout = true
            }
        }

        init(identifier: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            self.identifier = identifier
            addSubview(chip)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

        override var backgroundStyle: NSView.BackgroundStyle {
            didSet { chip.isEmphasized = backgroundStyle == .emphasized }
        }

        override func layout() {
            super.layout()
            // Ширина по содержимому, но не шире колонки: чип — плашка вокруг
            // текста, а растянутый на всю колонку выглядел бы кнопкой.
            let width = min(chip.intrinsicWidth, bounds.width - 8)
            chip.frame = NSRect(x: 4, y: 0, width: max(0, width), height: bounds.height)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var model: BrowserModel
        var actions: FolderActions
        var appState: AppState
        // Конкретный тип, а не NSTableView: координатору нужны buffer-команды и
        // быстрый просмотр, объявленные в подклассе. Создаётся она только в
        // makeNSView, поэтому другого типа тут и не бывает.
        weak var table: FileTableView?
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
        /// Ступень, которую таблица уже показывает. Опционал, а не .default:
        /// первое применение обязано выставить rowHeight, даже если масштаб
        /// совпал с умолчанием, — таблица приходит с высотой из makeNSView.
        private var renderedScale: ListScale?

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

        /// Применяет масштаб к таблице: высота строк и перестройка ячеек.
        ///
        /// Отдельно от reloadIfContentChanged: подпись содержимого при смене
        /// масштаба не меняется — тот же набор URL с теми же метаданными, — и
        /// проверка по ней ступень бы проглотила.
        func applyScaleIfChanged() {
            let scale = appState.scale
            guard scale != renderedScale, let table else { return }
            let isFirstApply = renderedScale == nil
            renderedScale = scale

            // Якорь снимаем до правки геометрии: rowHeight пересчитывает
            // раскладку сразу, и строка, прочитанная после него, была бы уже
            // из перестроенной таблицы — не та, что видел человек.
            //
            // Держимся за номер строки, а не за смещение в точках: высота
            // строк меняется, и прежнее смещение указало бы на другой файл —
            // тем дальше, чем ниже пользователь пролистал.
            let visible = table.rows(in: table.visibleRect)
            let anchor = visible.length > 0 ? visible.location : nil

            table.rowHeight = scale.rowHeight
            // Шапка на ступень мельче содержимого: она подпись к колонке, а не
            // данные. Кегль ставится в headerCell — заголовки рисует он, а не
            // ячейка строки, и шрифт таблицы их не касается.
            for column in table.tableColumns {
                column.headerCell.font = .systemFont(ofSize: scale.headerFontSize)
                // Ширину ведёт масштаб: рассчитанные под кегль 12 точки не
                // вмещают дату на 16 pt, и «28 авг. 2026 г., 15:37» обрезалось
                // бы на каждой строке.
                //
                // Ручную правку ширины это стирает, и так и задумано: она
                // нигде не сохраняется и живёт лишь до перезапуска, а
                // обрезанная дата — навсегда.
                guard let kind = Column(rawValue: column.identifier.rawValue) else { continue }
                let extra = kind == .name ? scale.nameColumnExtraWidth : 0
                column.width = kind.width * scale.columnWidthFactor + extra
            }
            // Высота шапки не считается от её шрифта сама: NSTableHeaderView
            // берёт её из своей рамки, и на крупной ступени заголовок обрезался
            // бы сверху и снизу.
            if let header = table.headerView {
                header.frame.size.height = ceil(scale.headerFontSize * 1.9)
            }

            // На первом применении восстанавливать нечего: таблица ещё пуста,
            // а noteHeightOfRows на пустом списке только зря считает.
            guard !isFirstApply else { return }

            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
            // Ячейки переиспользуются, и уже показанные держат прежний кегль:
            // без reloadData сменилась бы только высота строки, а шрифт с
            // иконкой остались бы от прошлой ступени.
            table.reloadData()
            // Выделение переживает reloadData само, но синхронизация модели с
            // таблицей на этом пути не идёт — восстанавливать его не нужно.

            // Ставим якорную строку под шапку, а не зовём scrollRowToVisible:
            // тот подтягивает строку минимальным движением и, если она и так
            // видна у нижнего края, не двигает скролл вовсе — список остался
            // бы на прежних точках, то есть на других файлах.
            if let anchor, anchor < table.numberOfRows,
               let scrollView = table.enclosingScrollView {
                scrollView.contentView.scroll(to: table.rect(ofRow: anchor).origin)
                // Без этого полоса прокрутки осталась бы на прежнем месте:
                // scroll(to:) двигает clip view мимо scroll view.
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
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

            // Ветка — чип, а не текст: серая строка неотличима от даты и
            // размера, и глаз не отделяет состояние проекта от свойств файла.
            if column == .branch {
                let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? BranchChipCell
                    ?? BranchChipCell(identifier: column.identifier)
                cell.scale = appState.scale
                cell.branch = item.branch
                cell.alphaValue = model.pane.isCut(item.url) ? 0.5 : 1.0
                return cell
            }

            // Переиспользуем ячейку: создание с нуля стоит 1.4 мс, а на экране их сорок.
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? FileCell
                ?? FileCell(identifier: column.identifier, showsIcon: column == .name)

            // До текста: шрифт ставит didSet масштаба, и присвоенный после он
            // переписал бы выравнивание строки под новый кегль лишний раз.
            cell.scale = appState.scale
            cell.textField?.stringValue = model.text(for: item, column: column.rawValue)
            cell.textField?.delegate = self
            cell.textField?.isEditable = column == .name
            cell.textField?.alignment = column == .size ? .right : .left
            cell.textField?.textColor = column == .name ? .labelColor : .secondaryLabelColor

            if column == .name {
                cell.imageView?.image = IconCache.icon(for: item, size: appState.scale.iconSize)
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
            refreshQuickLook()
        }

        /// Показывает в открытой панели то, что выделено сейчас.
        ///
        /// Проверка sharedPreviewPanelExists обязательна: обращение к shared()
        /// создаёт панель, и без неё каждая смена выделения поднимала бы её из
        /// небытия, хотя пользователь просмотр не открывал.
        func refreshQuickLook() {
            guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else { return }
            QLPreviewPanel.shared().reloadData()
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
            let item = model.items[table.clickedRow]
            // ⌘-двойной клик по папке открывает её вкладкой — как ссылку в
            // браузере. Одиночный ⌘-клик не трогаем: в NSTableView он
            // добавляет строку к выделению, и это нативное поведение macOS.
            if item.isDirectory, NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                appState.tabs.open(item.url, activate: false)
                return
            }
            model.open(item)
        }

        /// Открывает папку вкладкой по среднему клику. Зовётся из FileTableView:
        /// otherMouseUp до делегата не доходит — его нет в responder chain.
        func openInBackgroundTab(row: Int) {
            guard row >= 0, row < model.items.count else { return }
            let item = model.items[row]
            guard item.isDirectory else { return }
            appState.tabs.open(item.url, activate: false)
        }

        // MARK: - Сортировка

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            // Через appState, а не через model напрямую: сортировка общая для
            // всех вкладок и сохраняется между запусками, а записанная в свою
            // модель осталась бы у одной вкладки и умерла бы с приложением.
            appState.sort = SortSettings(key: key, ascending: descriptor.ascending)
            tableView.reloadData()
        }

        // MARK: - Переименование

        /// SwiftUI зовёт updateNSView на любое изменение модели, поэтому редактирование
        /// запускается один раз на элемент: иначе повторный makeFirstResponder сбивал бы
        /// курсор и выделение посреди набора имени.
        /// Прокручивает к файлу, к которому просили перейти из выдачи поиска.
        ///
        /// Прокрутка принадлежит NSScrollView, из модели её не сделать —
        /// поэтому запрос, а не свойство. Выделение к этому моменту уже стоит:
        /// его выставила модель, а syncSelection перенёс в таблицу.
        func revealIfNeeded() {
            guard let target = model.revealRequest, let table else { return }
            model.revealRequest = nil
            guard let row = model.items.firstIndex(where: { $0.url == target }) else { return }
            table.scrollRowToVisible(row)
        }

        /// Открывает панель по команде меню.
        ///
        /// Панель берёт ввод себе, поэтому фокус сначала возвращаем списку:
        /// иначе после клика по пункту меню первым респондером осталась бы
        /// таблица без фокуса, и панели некому было бы отдать себя в
        /// beginPreviewPanelControl.
        func showQuickLookIfNeeded() {
            guard appState.pendingQuickLook else { return }
            appState.pendingQuickLook = false
            guard let table else { return }
            table.window?.makeFirstResponder(table)
            table.toggleQuickLook()
        }

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
            // Внешнее обновление списка перезагружает таблицу и уводит фокус
            // из поля — набранное имя пропало бы под руками.
            model.isRenaming = true
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
            model.isRenaming = false
        }

        /// Элемент строки, в ячейке которой лежит поле. Нужен, когда редактор открыл
        /// сам AppKit: своего editingItem в этом случае нет.
        private func itemURL(forFieldIn field: NSTextField) -> URL? {
            guard let table else { return nil }
            // row(for:) отдаёт -1, если ячейку уже переиспользовали под другую строку.
            let row = table.row(for: field)
            guard model.items.indices.contains(row) else { return nil }
            return model.items[row].url
        }

        /// При переименовании выделяется только имя без расширения — как в проводнике.
        private func selectNameWithoutExtension(in field: NSTextField, item: FileItem) {
            guard !item.isDirectory else { return }
            let stem = item.url.deletingPathExtension().lastPathComponent
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: stem.count)
        }

        /// Правку, начатую самим AppKit, надо обставить теми же флагами, что и свою:
        /// иначе F2 и ⌘⌫ сработают как файловые команды прямо посреди набора имени,
        /// а фоновая перезагрузка списка уведёт фокус и сотрёт набранное.
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  editingItem == nil,
                  let url = itemURL(forFieldIn: field)
            else { return }
            editingItem = url
            originalName = url.lastPathComponent
            appState.isEditingText = true
            model.isRenaming = true
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
            // Правку начинает не только пункт меню: по клику в уже выделенную строку
            // редактор поднимает сам NSTableView, и renamingItem тогда пуст. Опора на
            // него теряла бы такое имя молча — поле показывало бы новое, файл оставался
            // старым. Поэтому элемент берём из строки, где лежит поле.
            guard let renaming = editingItem ?? itemURL(forFieldIn: field) else {
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

            if let item {
                add(to: menu, .open, #selector(menuOpen))
                // Вкладкой открывается только папка: файл в ней показать нечем.
                if item.isDirectory {
                    add(to: menu, .openInNewTab, #selector(menuOpenInNewTab))
                }
                menu.addItem(.separator())
            }

            add(to: menu, .copy, #selector(menuCopy))
            add(to: menu, .cut, #selector(menuCut))
            add(to: menu, .paste, #selector(menuPaste))
            add(to: menu, .copyPath, #selector(menuCopyPath))
            menu.addItem(.separator())

            if item != nil {
                add(to: menu, .rename, #selector(menuRename))
                // Пакетное — только при мультиселекции: для одного файла выше
                // есть обычное «Переименовать».
                if clickedTargets.count >= 2 {
                    add(to: menu, .batchRename, #selector(menuBatchRename))
                }
            }
            addCreateSubmenu(to: menu)
            menu.addItem(.separator())

            // Архивы: одна операция за раз, во время неё пункты неактивны
            // (пункт без action система выключает сама).
            if let item {
                let busy = model.isBusy
                if !item.isDirectory && ArchiveService.isArchive(item.url) {
                    add(to: menu, .extractHere, busy ? nil : #selector(menuExtractHere))
                    add(to: menu, .extractHere, busy ? nil : #selector(menuExtractTo), title: "Распаковать в…")
                } else {
                    let targets = clickedTargets
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

            // Кликнутый проект либо репозиторий текущей папки: стоя в
            // ~/PhpstormProjects, которая репозиторием не является, правый клик
            // по строке проекта обязан дать его операции — ради этого сценария
            // всё и затевалось. В обычной папке вне репозитория пунктов нет:
            // они были бы мёртвыми всегда и лишь удлиняли меню.
            if let repository = menuRepository {
                let busy = model.isBusy
                // Заголовком — имя ветки: кликнутая строка и выделенная суть
                // разные вещи, и без подписи Push уходил бы в проект, о котором
                // человек не думал.
                addBranchSubmenu(to: menu, repository: repository, busy: busy)
                menu.addItem(.separator())
            }

            let isFavorite = actions.isFavorite(folder)
            add(to: menu, .toggleFavorite, #selector(menuToggleFavorite),
                title: isFavorite ? "Убрать из избранного" : "Добавить в избранное",
                icon: MenuIcon.symbol(isFavorite ? "star.slash" : "star", .systemYellow))
            add(to: menu, .revealInFinder, #selector(menuRevealInFinder))

            if item != nil {
                menu.addItem(.separator())
                add(to: menu, .quickLook, #selector(menuQuickLook))
                add(to: menu, .properties, #selector(menuProperties))
                add(to: menu, .moveToTrash, #selector(menuMoveToTrash))
            }
        }

        /// Подменю «Создать»: папка и документы.
        ///
        /// Строится из DocumentTemplates, а не из CommandRegistry: реестр
        /// описывает команды с постоянным идентификатором, а шаблоны — это
        /// данные, у которых своего CommandID нет. «Новая папка» остаётся
        /// командой реестра — у неё есть свой ⇧⌘N.
        /// Операции репозитория одним пунктом с подменю.
        ///
        /// Свёрнуто, а не пять строк подряд: в этом меню их три десятка, и
        /// плоский git-блок занимал бы в нём треть высоты, хотя нужен реже
        /// «Копировать». Пункт назван именем ветки — так бывшая серая строка
        /// заголовка не исчезла, а стала самим пунктом и по-прежнему отвечает,
        /// к какому проекту относятся операции: кликнутая строка и выделенная
        /// суть разные вещи.
        private func addBranchSubmenu(to menu: NSMenu, repository: URL, busy: Bool) {
            // Из уже посчитанного, а не с диска: чтение задержало бы появление
            // меню, а на сетевом томе это те самые 13–21 мс, ради которых
            // ветка там не читается вовсе. Источник выбирается по цели: строка
            // годится, только когда репозиторий — она сама.
            let known = repository == model.currentRepository?.root
                ? model.currentRepository?.branch
                : model.items.first { $0.url == repository }?.branch
            let branch = known ?? GitRepository.branch(at: repository)

            let submenu = NSMenu()
            add(to: submenu, .gitPull, busy ? nil : #selector(menuGitPull))
            add(to: submenu, .gitPush, busy ? nil : #selector(menuGitPush))
            add(to: submenu, .gitSync, busy ? nil : #selector(menuGitSync))
            add(to: submenu, .gitFetch, busy ? nil : #selector(menuGitFetch))
            addBranches(to: submenu, repository: repository, busy: busy)
            submenu.addItem(.separator())
            add(to: submenu, .gitCopyBranch, #selector(menuGitCopyBranch))

            // Без ветки — слово «Репозиторий»: отделённая голова и нечитаемый
            // HEAD оставляют операции осмысленными, и пункт без названия был бы
            // хуже пункта с общим.
            let parent = NSMenuItem(title: branch ?? "Репозиторий", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            parent.image = MenuIcon.symbol(
                branch.map { GitRepository.isDetached($0) } == true
                    ? "point.3.connected.trianglepath.dotted"
                    : "point.topleft.down.to.point.bottomright.curvepath"
            )
            menu.addItem(parent)
        }

        /// Недавние ветки и вход в полный список.
        ///
        /// Пять, а не все: в рабочем репозитории их бывает семьдесят, и
        /// вывались бы они целиком — подменю ушло бы за край экрана.
        /// Локальные, потому что серверная требует создания ветки, и в общем
        /// списке без пояснения это выглядело бы обычным переходом.
        private func addBranches(to menu: NSMenu, repository: URL, busy: Bool) {
            // На сетевом томе не читаем вовсе: чтение синхронное, и git там
            // отвечает сотнями миллисекунд, а на отвалившемся сервере может не
            // ответить вовсе — меню не открылось бы до истечения таймаута SMB.
            // Та же причина, по которой ветка не читается для колонки.
            guard BrowserModel.isOnLocalVolume(repository) else { return }

            let branches = BranchReader.branches(at: repository)
            guard !branches.isEmpty else { return }

            menu.addItem(.separator())
            let header = NSMenuItem(title: "Недавние ветки", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for branch in branches.filter({ !$0.isRemote }).prefix(5) {
                let item = NSMenuItem(
                    title: branch.name,
                    // На текущей ветке пункт мёртв: git переключение на себя
                    // пропустит молча, но живой пункт, который ничего не
                    // делает, выглядит сломанным.
                    action: busy || branch.isCurrent ? nil : #selector(menuSwitchBranch(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = branch
                // Галочка, а не выделение цветом: нативный способ macOS
                // показать выбранное среди равных.
                item.state = branch.isCurrent ? .on : .off
                menu.addItem(item)
            }

            let all = NSMenuItem(
                title: "Все ветки…",
                action: busy ? nil : #selector(menuAllBranches),
                keyEquivalent: ""
            )
            all.target = self
            menu.addItem(all)
        }

        private func addCreateSubmenu(to menu: NSMenu) {
            let submenu = NSMenu()
            add(to: submenu, .newFolder, #selector(menuNewFolder), title: "Папка")

            let writable = !model.isReadOnlyVolume
            var lastGroup: TemplateGroup?
            for template in DocumentTemplates.all {
                // Разделитель перед группой, а не после каждой: иначе меню
                // закрывала бы висячая черта.
                if template.group != lastGroup {
                    submenu.addItem(.separator())
                    lastGroup = template.group
                }
                let item = NSMenuItem(
                    title: template.title,
                    action: writable ? #selector(menuCreateDocument(_:)) : nil,
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = template
                item.image = MenuIcon.document(extension: template.fileExtension)
                submenu.addItem(item)
            }

            let parent = NSMenuItem(title: "Создать", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            parent.image = MenuIcon.symbol("plus.square.on.square")
            menu.addItem(parent)
        }

        @objc private func menuCreateDocument(_ sender: NSMenuItem) {
            guard let template = sender.representedObject as? DocumentTemplate else { return }
            // Новый файл сразу уходит в переименование — как «Новая папка» и как
            // в проводнике: имя по умолчанию человеку почти всегда не нужно.
            appState.pendingRename = model.createDocument(template)
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

        /// Элементы, к которым относится команда: вся мультиселекция, если клик
        /// был по ней, иначе только кликнутый элемент.
        private var clickedTargets: [FileItem] {
            guard let item = clickedItem else { return [] }
            let selected = model.items.filter { model.pane.selection.contains($0.url) }
            if selected.count > 1, selected.contains(where: { $0.url == item.url }) {
                return selected
            }
            return [item]
        }

        /// Репозиторий, к которому относятся git-пункты меню.
        ///
        /// Кликнутая папка важнее текущей: в списке проектов правый клик по
        /// строке должен работать именно с ней. Внутри репозитория клик по
        /// файлу цели не меняет — операция затрагивает репозиторий целиком.
        private var menuRepository: URL? {
            // Спрашиваем файловую систему, а не смотрим на item.branch: ветка
            // заполняется вторым проходом загрузки, и до его конца пункты
            // пропадали бы из меню, появляясь через секунду сами собой. На
            // сетевом томе ветка не читается вовсе — там они не появились бы
            // никогда, то есть ровно в том сценарии, ради которого всё и
            // затевалось. Проверка дешёвая: одно обращение по уже известному
            // пути, тем же приёмом, что и в BrowserModel.gitTarget.
            if let item = clickedItem, item.isDirectory, GitRepository.isRepository(item.url) {
                return item.url
            }
            return model.currentRepository?.root
        }

        // Цель передаётся явно, а не берётся из выделения: правый клик по
        // невыделенной строке действует на неё — нативное поведение macOS, — и
        // без этого операция ушла бы в выделенный проект, то есть не в тот, по
        // которому кликнули. Само выделение при этом не трогается.
        @objc private func menuGitFetch() { model.gitFetch(at: menuRepository) }
        @objc private func menuGitPull() { model.gitPull(at: menuRepository) }
        @objc private func menuGitPush() { model.gitPush(at: menuRepository) }
        @objc private func menuGitSync() { model.gitSync(at: menuRepository) }
        @objc private func menuGitCopyBranch() { model.gitCopyBranch(at: menuRepository) }

        @objc private func menuSwitchBranch(_ sender: NSMenuItem) {
            guard let branch = sender.representedObject as? Branch else { return }
            model.gitSwitch(to: branch, at: menuRepository)
        }

        @objc private func menuAllBranches() {
            appState.pendingBranchSwitch = menuRepository
        }

        @objc private func menuCompress() {
            let targets = clickedTargets
            guard !targets.isEmpty else { return }
            onCompress(targets)
        }

        // От clickedTargets, как «Свойства» и «Архивировать»: правый клик по
        // мультиселекции действует на неё, а не на выделение панели.
        @objc private func menuBatchRename() {
            let targets = clickedTargets
            guard targets.count >= 2 else { return }
            appState.pendingBatchRename = targets
        }

        // Свойства от clickedTargets, а не от выделения: правый клик по
        // невыделенному файлу действует на него — как остальные пункты меню.
        /// Открывает быстрый просмотр для кликнутых объектов.
        ///
        /// Панель читает выделение, а правый клик по невыделенному файлу
        /// действует на него — поэтому выделение сначала приводим к тому, на
        /// чём меню вызвали. Иначе пункт показал бы не тот файл, по которому
        /// кликнули.
        @objc private func menuQuickLook() {
            let targets = clickedTargets
            guard !targets.isEmpty, let table else { return }
            model.pane.selection = Set(targets.map(\.url))
            syncSelection()
            table.window?.makeFirstResponder(table)
            table.toggleQuickLook()
        }

        @objc private func menuProperties() {
            let targets = clickedTargets
            guard !targets.isEmpty else { return }
            appState.pendingProperties = PropertiesBuilder.subject(for: targets)
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
        /// Открывает кликнутую папку вкладкой. Работает от clickedRow, как
        /// остальные пункты этого меню, а не от выделения.
        @objc private func menuOpenInNewTab() {
            guard let item = clickedItem, item.isDirectory else { return }
            appState.tabs.open(item.url, activate: true)
        }
        @objc private func menuCopy() { model.copy() }
        /// Клик по пустому месту копирует путь открытой папки — как «Открыть в
        /// Терминале» там же берёт текущую папку.
        @objc private func menuCopyPath() {
            let targets = clickedTargets
            model.copyPath(targets.isEmpty ? [model.pane.path] : targets.map(\.url))
        }
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
