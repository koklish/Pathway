import PathwayCore
import SwiftUI

/// Полоса вкладок между тулбаром и адресной строкой.
///
/// На SwiftUI, а не на NSTableView, в отличие от списка файлов: вкладок
/// единицы, и причины, уведшие FileListView в AppKit — тысячи строк и
/// стоимость ячейки, — здесь отсутствуют.
struct TabBarView: View {
    let tabs: TabsModel
    /// Вкладка, над которой держат курсор: только у неё видно крестик, иначе
    /// полоса пестрила бы кнопками закрытия.
    @State private var hovered: UUID?
    /// Перетаскиваемая вкладка. Хранится здесь, а не в модели: это состояние
    /// жеста, живущее до отпускания кнопки мыши.
    @State private var dragging: UUID?

    var body: some View {
        GeometryReader { geometry in
            let layout = TabWidths(
                available: geometry.size.width,
                tabs: tabs.tabs,
                activeID: tabs.active.id
            )
            // Вкладки упёрлись в минимальную ширину и больше не помещаются:
            // полоса прокручивается, и кнопка «+» встаёт особняком у правого
            // края — уехав вместе с вкладками, она пропала бы из виду.
            let overflows = layout.totalWidth(tabs: tabs.tabs) > layout.tabsWidth

            HStack(alignment: .bottom, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    // Вкладки прижаты к нижнему краю полосы: активная должна упираться
                    // в адресную строку без зазора, иначе закладка отрывается от
                    // содержимого и читается как висящая кнопка.
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(tabs.tabs) { tab in
                            tabItem(tab, width: layout.width(for: tab))
                                .onDrag {
                                    dragging = tab.id
                                    // Перетаскивание внутри полосы: содержимое провайдера
                                    // не используется, порядок меняет onDrop по dragging.
                                    return NSItemProvider(object: tab.id.uuidString as NSString)
                                }
                                .onDrop(
                                    of: [.text],
                                    delegate: TabDropDelegate(target: tab.id, tabs: tabs, dragging: $dragging)
                                )
                        }
                        // Пока вкладки помещаются, кнопка едет сразу за последней:
                        // прижатая к краю окна, она отрывается от полосы и читается
                        // как кнопка тулбара, а не как «ещё одна вкладка».
                        if !overflows {
                            newTabButton
                                .padding(.leading, 6)
                                .padding(.bottom, 4)
                        }
                    }
                    .padding(.leading, 6)
                }
                // Без распорки ScrollView сжимается по содержимому, и при
                // переполнении кнопке не осталось бы места справа.
                .frame(maxWidth: .infinity, alignment: .leading)

                if overflows {
                    newTabButton
                        .padding(.leading, 6)
                        .padding(.trailing, 6)
                        .padding(.bottom, 4)
                }
            }
        }
        .frame(height: 36)
        // Фон полосы притемнён вручную поверх системного, а не взят из
        // windowBackgroundColor: тот совпадает с controlBackgroundColor
        // до последнего разряда (оба чисто белые в светлой теме), и активная
        // закладка не отличалась бы от полосы ничем, кроме слабой тени.
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay(Color.primary.opacity(0.07))
        }
    }

    // MARK: - Вкладка

    private func tabItem(_ tab: TabState, width: CGFloat) -> some View {
        let isActive = tab.id == tabs.active.id
        // Ниже этого предела название и крестик не помещаются — остаётся один
        // значок, как в браузере при десятке вкладок.
        let showsTitle = width >= 60

        return HStack(spacing: 6) {
            tabIcon(tab)
                // Цветная иконка у неактивной вкладки перетягивала бы взгляд
                // на себя, обесценивая выделение активной.
                .opacity(isActive ? 1 : 0.55)

            if showsTitle {
                Text(tab.title)
                    // Активная — полужирным и в полный цвет, остальные приглушены:
                    // вес и контраст текста читаются раньше, чем разница фонов.
                    .font(.callout.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Распорка прижимает крестик к правому краю: без неё у вкладки с
                // коротким именем он оказывался посередине.
                Spacer(minLength: 4)

                closeButton(tab)
            }
        }
        // На узкой вкладке отступы урезаны: при 10 pt с каждой стороны на
        // значок остаётся 8 pt, и он сплющивается.
        .padding(.horizontal, showsTitle ? 10 : 4)
        .frame(width: width)
        // На 2 pt ниже полосы: сверху остаётся зазор, снизу закладка упирается
        // в край и переходит в адресную строку.
        .frame(height: 34)
        .background(tabBackground(isActive: isActive, isHovered: tab.id == hovered))
        .contentShape(.rect)
        .onTapGesture { tabs.select(id: tab.id) }
        .onHover { inside in
            hovered = inside ? tab.id : (hovered == tab.id ? nil : hovered)
        }
        .help(tab.browser.pane.path.path)
        .contextMenu {
            Button(tab.isPinned ? "Открепить вкладку" : "Закрепить вкладку") {
                tab.isPinned ? tabs.unpin(id: tab.id) : tabs.pin(id: tab.id)
            }
            Divider()
            Button("Закрыть вкладку") { tabs.close(id: tab.id) }
                .disabled(!tabs.canClose(id: tab.id))
            Button("Закрыть другие") { tabs.closeOthers(id: tab.id) }
                .disabled(tabs.tabs.count == 1)
            Button("Закрыть вкладки справа") { tabs.closeToTheRight(of: tab.id) }
                .disabled(tabs.tabs.last?.id == tab.id)
        }
        // Тонкая черта между соседними неактивными вкладками — вместо рамки у
        // каждой. Рядом с активной её нет: закладка отделяет себя сама, и
        // черта упиралась бы в её скруглённый край.
        .overlay(alignment: .trailing) {
            if needsSeparator(after: tab) {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 16)
                    // Черта короче закладки и должна стоять против текста, а не
                    // против её низа, который упирается в адресную строку.
                    .padding(.bottom, 2)
            }
        }
    }

    /// Значок вкладки: диск для сетевого тома, папка для всего остального.
    ///
    /// Сетевой — символом, а не иконкой тома от системы: `NSWorkspace` отдаёт
    /// для шары ту же папку, что и для локального каталога, и различить их в
    /// полосе было бы нечем.
    @ViewBuilder
    private func tabIcon(_ tab: TabState) -> some View {
        if tab.isPinned {
            // Закреплённая вкладка часто безымянна, и значок папки не сказал бы
            // о ней ничего: булавка объясняет и узость, и отсутствие крестика.
            Image(systemName: "pin.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tint)
                .frame(width: 16, height: 14)
        } else if tab.isOnNetworkVolume {
            Image(systemName: "externaldrive.connected.to.line.below")
                // Символ шире папки при равной высоте, поэтому размер задан
                // шрифтом, а не рамкой: растянутый до 14×14 квадрата, он
                // сплющился бы по горизонтали.
                .font(.system(size: 12))
                .foregroundStyle(.tint)
                .frame(width: 16, height: 14)
        } else {
            Image(nsImage: IconCache.folder)
                .resizable()
                .frame(width: 14, height: 14)
        }
    }

    /// Нужна ли черта справа от вкладки: только между двумя неактивными.
    private func needsSeparator(after tab: TabState) -> Bool {
        guard let index = tabs.tabs.firstIndex(where: { $0.id == tab.id }),
              index < tabs.tabs.count - 1
        else { return false }
        let activeID = tabs.active.id
        return tab.id != activeID && tabs.tabs[index + 1].id != activeID
    }

    /// Фон вкладки: активная — закладка, скруглённая только сверху; под
    /// курсором — едва заметная подсветка, остальные прозрачные.
    @ViewBuilder
    private func tabBackground(isActive: Bool, isHovered: Bool) -> some View {
        if isActive {
            // Тень только вверх и в стороны (y отрицательный): падая вниз, она
            // прочертила бы линию по стыку с адресной строкой и разрезала
            // закладку ровно там, где она должна с ней сливаться.
            TabShape(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 2, y: -1)
                // Контур обводит закладку по трём сторонам и отделяет её от
                // притемнённой полосы даже там, где тень теряется.
                .overlay {
                    TabShape(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
        } else {
            // Непрозрачная заливка даже без наведения: полностью прозрачная
            // фигура не ловит onHover, и подсветка не появлялась бы вовсе.
            TabShape(cornerRadius: 8)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0.001))
        }
    }

    /// Крестик виден у активной вкладки и под курсором. Место под него занято
    /// всегда: появляясь, он иначе сдвигал бы название.
    private func closeButton(_ tab: TabState) -> some View {
        // У закреплённой крестика нет вовсе: кнопка, которая не работает,
        // выглядит поломкой, а закрепление именно от закрытия и защищает.
        let isVisible = tabs.canClose(id: tab.id) && (tab.id == hovered || tab.id == tabs.active.id)

        return Button {
            tabs.close(id: tab.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .disabled(!isVisible)
        .help("Закрыть вкладку")
    }

    private var newTabButton: some View {
        Button {
            tabs.open(tabs.active.browser.pane.path, activate: true)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.separator, lineWidth: 1)
                        }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Новая вкладка (⌘T)")
    }
}

/// Ширина вкладок в полосе.
///
/// Считается во вью, а не в модели: зависит от размера окна, о котором
/// PathwayCore не знает и знать не должен. Отдельной структурой, а не парой
/// выражений в теле body: правило с тремя видами вкладок читается только
/// целиком.
///
/// @MainActor: читает состояние вкладок, а TabState живёт на главном акторе.
@MainActor
private struct TabWidths {
    /// Комфортная ширина, пока вкладок мало. Прежний maxWidth: три вкладки не
    /// должны растягиваться на всё окно.
    static let comfortable: CGFloat = 200
    /// Предел сжатия обычной вкладки: ровно иконка с отступами, название при
    /// ней пропадает совсем.
    static let minimum: CGFloat = 28
    /// Закреплённая не растягивается и не сжимается — только значок.
    static let pinned: CGFloat = 34
    /// Активная не сжимается ниже: полоса из безымянных иконок не даёт понять,
    /// где находишься, и у активной название нужно всегда — даже если она
    /// закреплена.
    static let activeMinimum: CGFloat = 90

    private let regular: CGFloat
    private let activeID: UUID
    /// Ширина, остающаяся вкладкам после вычета места под «+» и полей полосы.
    /// По ней вью сравнивает сумму ширин и решает, переполнена ли полоса.
    let tabsWidth: CGFloat

    init(available: CGFloat, tabs: [TabState], activeID: UUID) {
        self.activeID = activeID

        // Кнопка «+» (26) с отступами по 6 и левое поле полосы (6). Место под
        // кнопку вычтено всегда, даже когда она едет за последней вкладкой:
        // иначе при ширине впритык добавление кнопки само создавало бы
        // переполнение, она перескакивала бы к правому краю — и освободившееся
        // место снова делало бы полосу непереполненной.
        let reserved: CGFloat = 26 + 12 + 6
        let free = max(0, available - reserved)
        tabsWidth = free

        // Активная исключена из обеих групп: её ширина считается отдельно.
        let pinnedCount = tabs.filter { $0.isPinned && $0.id != activeID }.count
        let regularCount = tabs.count - pinnedCount - 1

        guard regularCount > 0 else {
            regular = Self.comfortable
            return
        }

        // Закреплённая активная берёт ровно activeMinimum и в дележе не
        // участвует; незакреплённая получает max(activeMinimum, regular), то
        // есть растёт вместе с остальными, и учитывать её надо как обычную.
        let activeIsPinned = tabs.contains { $0.id == activeID && $0.isPinned }

        let fixed = CGFloat(pinnedCount) * Self.pinned + (activeIsPinned ? Self.activeMinimum : 0)
        let rest = max(0, free - fixed)

        if activeIsPinned {
            regular = min(Self.comfortable, max(Self.minimum, rest / CGFloat(regularCount)))
            return
        }

        // Незакреплённая активная делит остаток наравне с обычными — иначе
        // разница между зарезервированным за неё минимумом и фактическим
        // max(activeMinimum, regular) не учитывалась бы ни в чьей доле: при
        // regular = 200 сумма ширин превышала бы полосу на сотню с лишним,
        // «+» уезжал за правый край, а горизонтальный ScrollView это скрывал.
        // Пока равная доля выше минимума активной, делим поровну на всех;
        // ниже — активная встаёт на минимум, остаток делят остальные.
        let equalShare = rest / CGFloat(regularCount + 1)
        let share = equalShare >= Self.activeMinimum
            ? equalShare
            : (rest - Self.activeMinimum) / CGFloat(regularCount)

        regular = min(Self.comfortable, max(Self.minimum, share))
    }

    /// Суммарная ширина всех вкладок. По ней вью решает, где встать кнопке
    /// «+»: сразу за последней закладкой или у правого края, если вкладки
    /// упёрлись в минимум и полоса прокручивается.
    func totalWidth(tabs: [TabState]) -> CGFloat {
        tabs.reduce(0) { $0 + width(for: $1) }
    }

    func width(for tab: TabState) -> CGFloat {
        if tab.id == activeID {
            // Активная закреплённая тоже показывает название: правило «видно,
            // где я» важнее экономии места.
            return tab.isPinned ? Self.activeMinimum : max(Self.activeMinimum, regular)
        }
        return tab.isPinned ? Self.pinned : regular
    }

    /// Влезает ли в такую ширину название. По этому же признаку прячется
    /// крестик: на узкой вкладке он съел бы место у иконки.
    func showsTitle(for tab: TabState) -> Bool {
        width(for: tab) >= 60
    }
}

/// Форма закладки: скругление сверху, низ прямой.
///
/// Своя фигура, а не RoundedRectangle с обрезкой: вкладка должна упираться в
/// адресную строку без скруглений снизу — иначе она отрывается от содержимого
/// и читается как плавающая кнопка, а не как закладка выбранной папки.
/// InsettableShape, а не просто Shape: без него нет strokeBorder, и контур
/// пришлось бы рисовать через stroke — тот кладёт линию по центру пути, и
/// половина её ширины вылезала бы за габарит закладки.
private struct TabShape: InsettableShape {
    let cornerRadius: CGFloat
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> TabShape {
        TabShape(cornerRadius: cornerRadius, inset: inset + amount)
    }

    func path(in rect: CGRect) -> Path {
        // Врезка по бокам и сверху, но не снизу: подняв нижний край, контур
        // оторвал бы закладку от адресной строки — ровно то слияние, ради
        // которого форма и заводилась.
        let rect = CGRect(
            x: rect.minX + inset, y: rect.minY + inset,
            width: max(0, rect.width - inset * 2), height: max(0, rect.height - inset)
        )
        var path = Path()
        let radius = min(cornerRadius, rect.height / 2, rect.width / 2)

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Перестановка вкладок перетаскиванием.
private struct TabDropDelegate: DropDelegate {
    let target: UUID
    let tabs: TabsModel
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = tabs.tabs.firstIndex(where: { $0.id == dragging }),
              let to = tabs.tabs.firstIndex(where: { $0.id == target })
        else { return }
        tabs.move(from: from, to: to)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    /// Подсветка цели не нужна: порядок меняется прямо во время перетаскивания,
    /// и вкладка уже стоит на новом месте.
    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
}
