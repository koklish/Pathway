import PathwayCore
import SwiftUI

/// Колонка графа в одной строке истории: линии дорожек и точка коммита.
///
/// Canvas, а не набор Path во вью: строк на экране до сорока, у каждой до
/// пяти линий, и двести SwiftUI-вью на кадр стоили бы дороже одной отрисовки.
struct GraphLane: View {
    let row: GraphRow?
    /// Коммит, на котором стоит рабочее дерево: рисуется кольцом.
    var isHead: Bool = false
    /// Самая верхняя строка списка: над ней истории нет, и линия из неё вверх
    /// не идёт. Без этого вертикаль упиралась бы в заголовок секции, обещая
    /// продолжение там, где его нет.
    var isFirst: Bool = false

    /// Шаг между дорожками. Тот же, что заложен в ширину колонки в CommitRow.
    private let step: CGFloat = 12
    private let radius: CGFloat = 3.5

    /// Фон панели: им выбивается середина кольца HEAD.
    ///
    /// Системный цвет, а не свой: он сам меняется со сменой оформления, и
    /// заданный вручную светлый оставил бы белую точку на тёмной теме.
    private var background: Color { Color(nsColor: .controlBackgroundColor) }

    var body: some View {
        Canvas { context, size in
            guard let row else { return }

            let middle = size.height / 2

            for link in row.links {
                var path = Path()
                let from = x(link.from)
                let to = x(link.to)

                if link.from == link.to {
                    // Прямая вертикаль через всю строку. У самой верхней —
                    // только от точки вниз: выше неё истории нет.
                    path.move(to: CGPoint(x: from, y: isFirst ? middle : 0))
                    path.addLine(to: CGPoint(x: from, y: size.height))
                } else {
                    // Переход вбок — от точки коммита ВНИЗ, к дорожке родителя:
                    // родитель лежит в строке ниже, и линия вверх уводила бы
                    // ветку туда, откуда она не растёт. Именно этим кривая
                    // отрывалась от точки слияния.
                    //
                    // Безье, а не угол: излом на строке в 24 пикселя читается
                    // как ошибка отрисовки, а не как ветвление.
                    path.move(to: CGPoint(x: from, y: middle))
                    path.addCurve(
                        to: CGPoint(x: to, y: size.height),
                        control1: CGPoint(x: from, y: middle + (size.height - middle) * 0.35),
                        control2: CGPoint(x: to, y: middle + (size.height - middle) * 0.65)
                    )
                }

                context.stroke(
                    path,
                    with: .color(Self.color(link.from == link.to ? link.from : link.to, row: row)),
                    lineWidth: 1.6
                )
            }

            let center = CGPoint(x: x(row.lane), y: middle)
            let color = Self.palette[row.color % Self.palette.count]

            // Верхняя половина дорожки коммита: от края строки до точки. Её
            // нельзя выразить связью — та означает отрезок через всю строку, —
            // и без неё первый коммит ветки висел бы оторванным от слияния,
            // которым эта ветка началась.
            if row.hasLineAbove && !isFirst {
                var incoming = Path()
                incoming.move(to: CGPoint(x: center.x, y: 0))
                incoming.addLine(to: center)
                context.stroke(incoming, with: .color(color), lineWidth: 1.6)
            }

            // Точка рисуется последней: линии, прошедшие под ней, не должны
            // перечёркивать её насквозь.

            // HEAD — кольцо, остальные коммиты — залитые кружки. Форма, а не
            // размер: увеличенная точка ломала бы ритм колонки, а кольцо
            // читается как «вы здесь» и на любом цвете дорожки.
            let size = isHead ? radius + 1.6 : radius
            let dot = Path(ellipseIn: CGRect(
                x: center.x - size, y: center.y - size,
                width: size * 2, height: size * 2
            ))

            if isHead {
                // Середина кольца выбивается фоном панели, иначе линия,
                // проходящая под точкой, просвечивала бы сквозь неё.
                context.fill(dot, with: .color(background))
                context.stroke(dot, with: .color(color), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(color))
            }
        }
    }

    private func x(_ lane: Int) -> CGFloat {
        // Дорожки дальше пятой сводятся к пятой: колонка шире съедала бы
        // сообщения, ради которых список и открывают.
        CGFloat(min(lane, 4)) * step + step / 2 + 2
    }

    /// Цвет линии. Дорожка коммита красится цветом строки, остальные —
    /// собственным индексом: иначе сквозная линия чужой ветки меняла бы цвет
    /// на каждой строке, через которую проходит.
    private static func color(_ lane: Int, row: GraphRow) -> Color {
        palette[(lane == row.lane ? row.color : lane) % palette.count]
    }

    /// Палитра дорожек: пять оттенков по кругу.
    ///
    /// Фиксированные цвета, а не системный акцент: акцентом красится ветка, на
    /// которой стоит человек, и совпади он с цветом дорожки — «где я» перестало
    /// бы читаться. Оттенки разведены по тону, а не по яркости: на тёмной теме
    /// светлые различаются, на светлой — тёмные, а тон работает на обеих.
    private static let palette: [Color] = [
        Color(red: 0.49, green: 0.36, blue: 1.0),
        Color(red: 0.25, green: 0.73, blue: 0.31),
        Color(red: 0.89, green: 0.70, blue: 0.25),
        Color(red: 0.31, green: 0.79, blue: 0.69),
        Color(red: 0.97, green: 0.51, blue: 0.40),
    ]
}
