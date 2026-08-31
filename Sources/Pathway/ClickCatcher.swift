import AppKit
import PathwayCore
import SwiftUI

/// Невидимый слой под содержимым окна: ловит клики, не доставшиеся ни одному
/// контролу, — по отступам, фону, статус-бару. Нужен, чтобы клик «в пустое место»
/// снимал фокус с адресной строки, как в Проводнике и Finder.
struct ClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? CatcherView)?.onClick = onClick
    }

    private final class CatcherView: NSView {
        var onClick: () -> Void = {}

        override func mouseDown(with event: NSEvent) {
            onClick()
            super.mouseDown(with: event)
        }
    }
}

/// Слой, ловящий только правый клик, — например, под чипом ветки, где левая
/// кнопка занята открытием меню.
///
/// Отдельная вью, а не .contextMenu: тот показывает меню, а здесь правый клик
/// сразу выполняет действие — меню ради одного пункта стоило бы лишнего клика.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? CatcherView)?.onRightClick = onRightClick
    }

    private final class CatcherView: NSView {
        var onRightClick: () -> Void = {}

        // rightMouseUp, а не Down: действие по отпусканию — правило macOS,
        // и по нажатию оно срабатывало бы до того, как человек передумал.
        override func rightMouseUp(with event: NSEvent) {
            onRightClick()
        }

        // Меню по умолчанию подавляется: без этого AppKit после нашего
        // обработчика показал бы пустое системное меню поверх панели.
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }
}

/// Имя системы координат окна для жестов изменения размера.
///
/// Общее для всех ручек: мерить сдвиг курсора можно только в системе, которая
/// сама от этого сдвига не движется.
let resizeCoordinateSpace = "pathway.resize"

/// Вертикальная полоса на границе панели: тянет её ширину мышью.
///
/// Жест меряется в координатах окна, а не своих. Ручка лежит на краю панели и
/// при расширении едет вместе с ним: в собственной системе отсчёта курсор,
/// сдвинувшийся на 10 pt, после переезда ручки под него оказывается снова на
/// нуле — ширина откатывается назад, на следующем кадре снова растёт, и это
/// колебание видно как дёрганье. Неподвижная система отсчёта убирает обратную
/// связь целиком.
struct PanelResizeHandle: View {
    /// Текущая ширина во время перетаскивания; nil — границу не тянут.
    @Binding var width: CGFloat?
    /// Ширина, с которой начинается перетаскивание, когда своей ещё нет.
    let initialWidth: CGFloat
    /// Ширина и точка курсора на момент начала жеста.
    @State private var start: (width: CGFloat, x: CGFloat)?
    /// Итоговая ширина по отпусканию кнопки — её и сохраняют.
    let onFinish: (CGFloat) -> Void

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            // Полоса захвата шире разделителя: попасть мышью в один пиксель
            // нельзя. Смещение влево — чтобы она лежала на самой границе, а не
            // отъедала край панели.
            .frame(width: 7)
            .contentShape(Rectangle())
            .offset(x: -3)
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(resizeCoordinateSpace))
                    .onChanged { value in
                        // Точка отсчёта запоминается один раз за жест и в
                        // координатах окна. От translation здесь пришлось
                        // отказаться: он считается от startLocation, который
                        // SwiftUI пересчитывает при переезде вью.
                        let origin = start ?? (width ?? initialWidth, value.startLocation.x)
                        start = origin

                        // Границы: уже 300 колонки истории слипаются, шире 640
                        // панель съедает список файлов.
                        width = ResizeDrag.size(
                            start: origin.width,
                            from: origin.x, to: value.location.x,
                            // Панель прижата к правому краю: движение влево её
                            // расширяет.
                            growth: .inverted, limits: 300...640
                        )
                    }
                    .onEnded { _ in
                        if let final = width { onFinish(final) }
                        start = nil
                    }
            )
    }
}
