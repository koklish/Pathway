import PathwayCore
import SwiftUI

/// Одна панель сплита: своя полоса вкладок, своя адресная строка и свой
/// список файлов.
///
/// Полоса вкладок — у каждой панели своя, а не одна на окно: общая полоса
/// показывала бы вкладки только активной половины, и при включении сплита
/// вкладки левой панели пропадали из виду целиком — взамен поднималась бы
/// свежесозданная правая группа с единственной вкладкой.
///
/// Адресная строка внутри панели по той же причине: одна строка на две папки
/// показывала бы путь только активной половины и молчала о второй — то есть
/// врала бы о том, где человек находится.
struct PaneView: View {
    let group: PaneGroup
    let tabs: TabsModel
    let actions: FolderActions
    @Bindable var appState: AppState
    @Binding var renamingItem: URL?
    /// Перетаскиваемая вкладка. Приходит общей на обе панели сверху: свой
    /// @State у каждой полосы не дал бы принимающей стороне узнать, что за
    /// вкладку несут, и перенос между панелями был бы невозможен.
    @Binding var draggingTab: UUID?

    /// Модель активной вкладки этой панели — не `appState.browser`: тот отдаёт
    /// активную панель, и неактивная половина рисовала бы чужую папку.
    private var model: BrowserModel { tabs.active.browser }

    /// Панель, которой адресованы команды и клавиатура.
    private var isActive: Bool { appState.panes.activeGroup == group }

    var body: some View {
        VStack(spacing: 0) {
            // Полоса вкладок этой панели: при сплите каждая половина ведёт
            // свой набор, и клик по вкладке заодно фокусирует панель жестом
            // ниже.
            TabBarView(
                tabs: tabs, group: group, panes: appState.panes,
                dragging: $draggingTab
            )
            Divider()
            // Цель обучающего тура помечает MainWindow, снаружи: подсветить
            // адресные строки обеих панелей значило бы показать два выреза под
            // одну подпись шага.
            AddressBarView(model: model, search: appState.search)
            Divider()
            content
        }
        // Клик в SwiftUI-области панели — полосу вкладок, адресную строку —
        // делает её активной. simultaneousGesture, а не onTapGesture: обычный
        // жест съел бы клики у вложенных вью.
        //
        // Список файлов этот жест не покрывает: клики внутри NSTableView до
        // SwiftUI-жестов предков не доходят, и список фокусирует свою панель
        // сам, через onFocusPane в FileTableView.
        .simultaneousGesture(
            TapGesture().onEnded { appState.panes.focus(group) }
        )
        // Неактивная панель приглушена — тем же приёмом, что и неактивное окно
        // в macOS: выделение в ней остаётся видимым, но не спорит за внимание с
        // той половиной, где идёт работа. Это единственный признак активности:
        // рамка вокруг активной панели оказалась избыточной — при двух
        // половинах и так видно, где светло, а лишняя цветная линия только
        // шумит.
        .opacity(isActive || !appState.panes.isSplit ? 1 : 0.72)
    }

    @ViewBuilder
    private var content: some View {
        // Поиск живёт в активной панели: он один на приложение, и выдача,
        // показанная в обеих половинах сразу, дублировала бы сама себя.
        if appState.search.isActive, isActive {
            SearchResultsView(search: appState.search, model: model)
        } else {
            FileListView(
                model: model, actions: actions, appState: appState,
                renamingItem: $renamingItem,
                onCompress: { items in
                    appState.pendingCompress = items
                },
                onFocusPane: { appState.panes.focus(group) }
            )
            // Своя таблица на вкладку — и на панель: id включает сторону, иначе
            // две панели на одной вкладке делили бы один NSScrollView, и скролл
            // одной половины уезжал бы вслед за другой.
            .id("\(group.rawValue)-\(tabs.active.id)")
        }
    }
}
