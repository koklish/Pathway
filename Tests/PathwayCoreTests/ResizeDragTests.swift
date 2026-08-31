import Foundation
import Testing

@testable import PathwayCore

@Suite("Пересчёт размера при перетаскивании границы")
struct ResizeDragTests {

    @Test("ширина растёт, когда границу тянут влево")
    func widthGrowsWhenDraggedLeft() {
        // Панель прижата к правому краю: движение курсора влево её расширяет.
        let width = ResizeDrag.size(start: 372, from: 800, to: 790, growth: .inverted, limits: 300...640)

        #expect(width == 382)
    }

    @Test("ширина уменьшается, когда границу тянут вправо")
    func widthShrinksWhenDraggedRight() {
        let width = ResizeDrag.size(start: 372, from: 800, to: 812, growth: .inverted, limits: 300...640)

        #expect(width == 360)
    }

    @Test("повторный кадр при неподвижном курсоре даёт ту же величину")
    func sameCursorGivesSameSize() {
        // Главная проверка: ради неё расчёт и переехал в координаты окна.
        // Точка отсчёта берётся один раз за жест, поэтому два кадра с курсором
        // в одном месте дают одно значение. Считай сдвиг от самой ручки — она
        // едет вместе с границей, и второй кадр вернул бы исходные 372, третий
        // снова 382: это колебание и видно как дёрганье.
        let first = ResizeDrag.size(start: 372, from: 800, to: 790, growth: .inverted, limits: 300...640)
        let second = ResizeDrag.size(start: 372, from: 800, to: 790, growth: .inverted, limits: 300...640)

        #expect(first == second)
    }

    @Test("величина считается от начала жеста, а не от прошлого кадра")
    func measuredFromGestureStart() {
        // Курсор прошёл 10 pt, потом ещё 10. Обе точки меряются от одного
        // начала: складывай приращения — панель уезжала бы вдвое быстрее
        // курсора, потому что каждый кадр добавлял бы весь пройденный путь.
        let after10 = ResizeDrag.size(start: 372, from: 800, to: 790, growth: .inverted, limits: 300...640)
        let after20 = ResizeDrag.size(start: 372, from: 800, to: 780, growth: .inverted, limits: 300...640)

        #expect(after10 == 382)
        #expect(after20 == 392)
    }

    @Test("высота секции растёт, когда разделитель тянут вниз")
    func heightGrowsWhenDraggedDown() {
        // Секция лежит над разделителем: движение вниз её увеличивает — знак
        // противоположен ширине панели, прижатой к правому краю.
        let height = ResizeDrag.size(start: 220, from: 400, to: 430, growth: .direct, limits: 90...460)

        #expect(height == 250)
    }

    @Test("величина не выходит за границы")
    func staysWithinLimits() {
        let tooWide = ResizeDrag.size(start: 372, from: 800, to: 300, growth: .inverted, limits: 300...640)
        let tooNarrow = ResizeDrag.size(start: 372, from: 800, to: 1400, growth: .inverted, limits: 300...640)

        #expect(tooWide == 640)
        #expect(tooNarrow == 300)
    }
}
