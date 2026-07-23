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
        ScrollView(.horizontal, showsIndicators: false) {
            // Вкладки прижаты к нижнему краю полосы: активная должна упираться
            // в адресную строку без зазора, иначе закладка отрывается от
            // содержимого и читается как висящая кнопка.
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(tabs.tabs) { tab in
                    tabItem(tab)
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
                newTabButton
                    .padding(.leading, 6)
                    .padding(.bottom, 4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
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

    private func tabItem(_ tab: TabState) -> some View {
        let isActive = tab.id == tabs.active.id

        return HStack(spacing: 6) {
            Image(nsImage: IconCache.folder)
                .resizable()
                .frame(width: 14, height: 14)
                // Цветная иконка у неактивной вкладки перетягивала бы взгляд
                // на себя, обесценивая выделение активной.
                .opacity(isActive ? 1 : 0.55)

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
        .padding(.horizontal, 10)
        .frame(minWidth: 120, maxWidth: 220)
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
            Button("Закрыть вкладку") { tabs.close(id: tab.id) }
                .disabled(tabs.tabs.count == 1)
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
        let isVisible = tabs.tabs.count > 1 && (tab.id == hovered || tab.id == tabs.active.id)

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
