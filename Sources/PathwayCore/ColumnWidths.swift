import Foundation

/// Ширины колонок списка файлов, настроенные вручную.
///
/// Настройка приложения, а не папки: живёт в TabsModel рядом с sort и scale,
/// одна на все вкладки. Своё папочное значение потребовало бы хранилища
/// «путь → ширины» с вопросом, когда его чистить, — а жалоба, ради которой всё
/// затевалось, звучит как «сбрасывается на умолчание», то есть про общую
/// настройку, а не про папочную.
///
/// **Хранятся только те колонки, которые тянули руками.** Отсутствие записи
/// значит «ширину не трогали» и отдаёт колонку во власть масштаба — заполни мы
/// словарь стартовыми значениями всех колонок, ползунок размера перестал бы
/// двигать ширину сразу, ещё до того, как пользователь что-то настроил.
public struct ColumnWidths: Equatable, Sendable {
    /// Идентификатор колонки → ширина в точках.
    private var widths: [String: CGFloat]

    /// Ниже этого колонку не сохраняем: столько же стоит minWidth у таблицы, а
    /// значение из будущего билда с другим минимумом иначе схлопнуло бы колонку
    /// в нечитаемую полоску.
    public static let minimum: CGFloat = 50

    /// Верхняя граница вменяемого: ширину больше экрана не задать мышью, но
    /// испорченный plist такое значение принесёт, и колонка вытеснила бы все
    /// остальные за пределы окна.
    public static let maximum: CGFloat = 2000

    public static let `default` = ColumnWidths([:])

    public init(_ widths: [String: CGFloat] = [:]) {
        self.widths = widths.filter { Self.isValid($0.value) }
    }

    /// Ширина колонки или nil, если её не настраивали.
    public func width(for column: String) -> CGFloat? {
        widths[column]
    }

    /// Запоминает ширину колонки. Значение вне разумных границ отбрасывается:
    /// источник здесь — перетаскивание мышью и содержимое plist, и ни то ни
    /// другое не обязано быть в диапазоне.
    public mutating func set(_ width: CGFloat, for column: String) {
        guard Self.isValid(width) else { return }
        widths[column] = width
    }

    /// Настраивали ли эту колонку вручную.
    ///
    /// Отдельный вопрос, а не проверка `width(for:) != nil` на месте вызова:
    /// именно от него зависит, слушается ли колонка ползунка масштаба, и
    /// смысл «настроена руками» стоит называть по имени.
    public func isCustomized(_ column: String) -> Bool {
        widths[column] != nil
    }

    /// Представление для UserDefaults: словарь чисел переживает plist как есть.
    public var storage: [String: Double] {
        widths.mapValues(Double.init)
    }

    public init(storage: [String: Double]) {
        self.init(storage.mapValues { CGFloat($0) })
    }

    /// NaN и бесконечность отсеиваются наравне с выходом за границы: сравнения
    /// с ними всегда ложны, и такое значение прошло бы проверку диапазона,
    /// записанную наивно.
    private static func isValid(_ width: CGFloat) -> Bool {
        width.isFinite && width >= minimum && width <= maximum
    }
}
