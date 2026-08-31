import AppKit
import PathwayCore
import SwiftUI

/// Чип ветки: скруглённая плашка со значком и именем.
///
/// Своё рисование, а не NSTextField с фоном: поле внутри ячейки таблицы стоит
/// дороже отрисованной строки, а редактировать этот текст не нужно. Ручной
/// layout по той же причине, что и в FileCell — Auto Layout здесь измерен в
/// 1.4 мс на ячейку, то есть 56 мс на экран при скролле.
final class BranchChipView: NSView {

    /// Что показывает чип. Отдельная структура, а не набор свойств: вью
    /// перерисовывается по присваиванию целиком, и забыть одно поле нельзя.
    struct Content: Equatable {
        let branch: String
        /// Отделённая голова: ветки нет, показан короткий хеш.
        let isDetached: Bool
        /// Сколько файлов затронуто; 0 — чисто либо статус ещё не досчитан.
        let changedFiles: Int
        /// Расхождение с сервером; nil — считать не с чем или ещё не считали.
        let ahead: Int?
        let behind: Int?

        var isDirty: Bool { changedFiles > 0 }

        init(branch: String, isDetached: Bool = false, changedFiles: Int = 0,
             ahead: Int? = nil, behind: Int? = nil) {
            self.branch = branch
            self.isDetached = isDetached
            self.changedFiles = changedFiles
            self.ahead = ahead
            self.behind = behind
        }
    }

    var content: Content? {
        didSet {
            guard content != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Чип на выделенной строке. Синий на синем фоне выделения исчез бы
    /// целиком, поэтому там плашка становится полупрозрачно-белой.
    var isEmphasized: Bool = false {
        didSet {
            guard isEmphasized != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Курсор над чипом: плашка становится плотнее.
    ///
    /// Без подъёма и тени, в отличие от чипа в адресной строке: там чип —
    /// кнопка, а здесь левый клик принадлежит выделению строки, и обещать
    /// нажатие было бы враньём. Подсветка говорит лишь «здесь есть меню по
    /// правой кнопке».
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Область отслеживания курсора.
    ///
    /// Пересоздаётся в updateTrackingAreas, а не ставится один раз: строки
    /// таблицы переиспользуются и меняют размер при прокрутке и смене
    /// масштаба, а область с прежними границами ловила бы курсор не там.
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }

        // Область по плашке, а не по всей ячейке: колонка шире чипа, и курсор
        // в её пустой части подсвечивал бы плашку, до которой не дотянулся.
        let area = NSTrackingArea(
            rect: plateRect(),
            // activeInKeyWindow: следить за курсором в фоновом окне незачем,
            // а .mouseEntered без него не приходит вовсе.
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        tracking = area

        // Курсор мог остаться внутри после прокрутки — тогда mouseEntered уже
        // не придёт, и подсветка залипла бы на строке, из-под которой чип уехал.
        if let window, let point = window.mouseLocationOutsideOfEventStream as CGPoint? {
            let local = convert(point, from: nil)
            isHovered = plateRect().contains(local) && window.isKeyWindow
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Показать меню репозитория. Ставит ячейка; nil — чип не кликабелен.
    var onClick: (() -> NSMenu?)?
    /// Позвать после закрытия меню: цель операции живёт, пока меню на экране.
    var onMenuClosed: (() -> Void)?

    /// События мыши берём только на самой плашке.
    ///
    /// Колонка шире чипа, и отдай мы ей всю ячейку — клик по пустому месту
    /// справа от плашки открывал бы меню вместо выделения строки, а протянуть
    /// оттуда рамку выделения стало бы нельзя.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onClick != nil, content != nil else { return nil }
        return plateRect().contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { showMenu() }

    /// Правая кнопка — то же меню.
    ///
    /// rightMouseDown, а не menu(for:): системный путь показал бы меню строки,
    /// собранное делегатом таблицы, и правый клик по чипу давал бы не то же
    /// самое, что левый.
    override func rightMouseDown(with event: NSEvent) { showMenu() }

    private func showMenu() {
        guard let menu = onClick?() else { return }
        // От нижнего края плашки: меню раскрывается под чипом, не накрывая его,
        // — так видно, к какой строке оно относится.
        let plate = plateRect()
        menu.popUp(positioning: nil, at: NSPoint(x: plate.minX, y: plate.maxY + 2), in: self)
        onMenuClosed?()
    }

    /// Кегль имени ветки. Задаёт весь размер чипа: плашка, значок, отступы и
    /// счётчик считаются от него, поэтому масштабировать чип — значит задать
    /// одно это число.
    ///
    /// 10.5 — размер, на котором чип жил до появления масштаба; он же остаётся
    /// у адресной строки и меню, которые ползунку не подчиняются.
    var fontSize: CGFloat = 10.5 {
        didSet {
            guard fontSize != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Пропорции подобраны на исходном кегле 10.5 и от него же выводятся:
    /// набор констант на каждую ступень пришлось бы держать согласованным
    /// вручную, а формула делает это сама.
    private var height: CGFloat { ceil(fontSize * 1.6) }
    private var iconSize: CGFloat { ceil(fontSize * 0.95) }
    private var horizontalPadding: CGFloat { ceil(fontSize * 0.57) }
    private var gap: CGFloat { ceil(fontSize * 0.38) }
    /// Точка «есть незакоммиченные изменения».
    private var dotSize: CGFloat { ceil(fontSize * 0.45) }

    private var font: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .medium) }
    private var counterFont: NSFont {
        // Счётчик мельче имени на те же пол-пункта, что и раньше: он служебный.
        .monospacedDigitSystemFont(ofSize: fontSize - 0.5, weight: .regular)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }

        let tint = self.tint(for: content)
        let plate = plateRect()
        let path = NSBezierPath(roundedRect: plate, xRadius: plate.height / 2, yRadius: plate.height / 2)

        // Заливка светлее обводки: полностью залитый цветом чип на строке
        // таблицы спорил бы по весу с именем файла в соседней колонке.
        // Наведение добавляется к состоянию строки, а не заменяет его: на
        // выделенной строке чип уже плотнее, и одинаковые числа для обоих
        // случаев означали бы, что там курсор не отзывается вовсе.
        let base = isEmphasized ? (fill: 0.22, stroke: 0.45) : (fill: 0.12, stroke: 0.30)
        let fill = base.fill + (isHovered ? 0.10 : 0)
        let stroke = base.stroke + (isHovered ? 0.25 : 0)
        tint.withAlphaComponent(fill).setFill()
        path.fill()
        tint.withAlphaComponent(stroke).setStroke()
        path.lineWidth = 1
        path.stroke()

        var x = plate.minX + horizontalPadding

        // Значок только если влезает целиком: на колонке, утащенной до
        // минимума, он торчал бы из плашки наружу.
        if plate.width >= horizontalPadding * 2 + iconSize,
           let icon = icon(for: content) {
            let frame = NSRect(
                x: x,
                y: plate.midY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            x = frame.maxX + gap
        }

        // Хвост считается первым: имя обрезается по остатку, а не наоборот —
        // иначе счётчик уехал бы за край плашки на длинных именах.
        let tail = tailText(for: content)
        let tailWidth = tail.map { $0.size(withAttributes: [.font: counterFont]).width } ?? 0
        let dirtyWidth = dirtyBlockWidth(for: content)
        let available = plate.maxX - horizontalPadding - x
            - tailWidth - (tail == nil ? 0 : gap) - dirtyWidth

        let style = NSMutableParagraphStyle()
        // По центру: начало говорит о типе ветки, конец — о номере задачи,
        // а середина у длинных имён вроде feature/SDLC/1897 всегда одна и та же.
        style.lineBreakMode = .byTruncatingMiddle
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: tint,
            .paragraphStyle: style,
        ]
        let nameRect = NSRect(
            x: x,
            y: plate.midY - font.capHeight / 2 - 2,
            width: max(0, available),
            height: height
        )
        (content.branch as NSString).draw(in: nameRect, withAttributes: nameAttributes)

        var right = plate.maxX - horizontalPadding

        if let tail {
            let size = tail.size(withAttributes: [.font: counterFont])
            let rect = NSRect(
                x: right - size.width,
                y: plate.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            (tail as NSString).draw(in: rect, withAttributes: [
                .font: counterFont,
                .foregroundColor: tint.withAlphaComponent(0.85),
            ])
            right = rect.minX - gap
        }

        if content.isDirty {
            let number = String(content.changedFiles)
            let size = number.size(withAttributes: [.font: counterFont])
            let rect = NSRect(
                x: right - size.width,
                y: plate.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            (number as NSString).draw(in: rect, withAttributes: [
                .font: counterFont,
                .foregroundColor: tint,
            ])

            // Точка остаётся рядом с числом, а не заменяется им: она дублирует
            // цвет, а различение состояния по одному оттенку отсекает тех, кто
            // его не видит. Голое число такой подсказкой не служит — «3» само
            // по себе могло бы значить что угодно, включая счётчик коммитов.
            let dot = NSRect(
                x: rect.minX - gap - dotSize,
                y: plate.midY - dotSize / 2,
                width: dotSize,
                height: dotSize
            )
            tint.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    /// Ширина, при которой чип показывает содержимое целиком.
    ///
    /// Нужна адресной строке: там чип обязан вместить имя без обрезки, иначе
    /// ветка, ради которой индикатор и существует, читалась бы наполовину.
    var intrinsicWidth: CGFloat {
        guard let content else { return 0 }
        let name = content.branch.size(withAttributes: [.font: font]).width
        let tail = tailText(for: content)
            .map { $0.size(withAttributes: [.font: counterFont]).width + gap } ?? 0
        return horizontalPadding * 2 + iconSize + gap + name + tail + dirtyBlockWidth(for: content)
    }

    // MARK: - Оформление

    private func plateRect() -> NSRect {
        NSRect(
            x: 0,
            y: (bounds.height - height) / 2,
            width: bounds.width,
            height: height
        )
    }

    private func tint(for content: Content) -> NSColor {
        if isEmphasized { return .white }
        // Янтарный, а не красный: красный в файловом менеджере уже значит
        // «ошибка», а незакоммиченные изменения — норма, а не беда.
        return content.isDirty ? .systemOrange : .controlAccentColor
    }

    /// Готовые значки: имя символа плюс состояние цвета.
    ///
    /// Кэш обязателен: пересборка с перекраской стоит 0.23 мс на чип против
    /// 0.07 мс с кэшем, то есть 9.3 мс на экран сорока строк вместо 2.8 —
    /// больше половины бюджета кадра на одну колонку. Та же причина, по
    /// которой в проекте появился IconCache. Вариантов всего четыре:
    /// два символа на два состояния цвета плюс белый для выделения.
    private static var iconCache: [String: NSImage] = [:]

    private func icon(for content: Content) -> NSImage? {
        // Разные значки обязательны: a3f91c2 без значка выглядит как ветка со
        // странным именем, и отличить одно от другого можно было бы только
        // зная, что имена веток не бывают семисимвольным hex.
        // Два узла на кривой, а не arrow.trianglehead.branch: та вилка смотрит
        // стрелками вверх и в размере 10 pt читается перевёрнутой, а этот
        // символ симметричен по диагонали и узнаётся в любом масштабе.
        let name = content.isDetached
            ? "point.3.connected.trianglepath.dotted"
            : "point.topleft.down.to.point.bottomright.curvepath"
        let color = tint(for: content)
        // Акцентный цвет система меняет на лету, поэтому он часть ключа, а не
        // предположение: иначе после смены оформления значки остались бы
        // прежними до перезапуска.
        let key = "\(name)|\(color.description)"
        if let cached = Self.iconCache[key] { return cached }

        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configured = image.withSymbolConfiguration(
            .init(pointSize: iconSize, weight: .medium)
        ) ?? image
        let tinted = configured.tinted(with: color)
        Self.iconCache[key] = tinted
        return tinted
    }

    /// Ширина блока «точка + число правок» вместе с отступом перед ним.
    ///
    /// Считается в одном месте для отрисовки и для intrinsicWidth: разойдись
    /// они — чип обрезал бы собственный счётчик ровно на разницу.
    private func dirtyBlockWidth(for content: Content) -> CGFloat {
        guard content.isDirty else { return 0 }
        let number = String(content.changedFiles).size(withAttributes: [.font: counterFont]).width
        return dotSize + gap + number + gap
    }

    /// Счётчик расхождения: «↑9», «↓2» или «↑9 ↓2».
    private func tailText(for content: Content) -> String? {
        var parts: [String] = []
        if let ahead = content.ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind = content.behind, behind > 0 { parts.append("↓\(behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

private extension NSImage {
    /// Перекрашивает символ: SF Symbols приходит чёрным, а чип рисует его
    /// цветом состояния.
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Чип в адресной строке

/// Тот же чип для SwiftUI: адресная строка целиком на SwiftUI, и городить
/// NSViewRepresentable ради одной кнопки незачем.
///
/// Здесь чип показывает и статус: для текущей папки git status уже посчитан
/// в BrowserModel.currentRepository, платить за него второй раз не нужно.
struct BranchChipLabel: View {
    let repository: RepositoryState
    let branch: String
    /// Курсор над чипом. Приходит снаружи: наведение отслеживает та вью,
    /// которая ловит и правый клик, — два .onHover на вложенных вью спорили бы
    /// друг с другом, и подсветка мигала бы на границе между ними.
    var isHovered: Bool = false
    /// Кнопка нажата и не отпущена.
    var isPressed: Bool = false

    private var tint: Color {
        // Янтарный, а не красный: красный в файловом менеджере уже значит
        // «ошибка», а незакоммиченные изменения — норма, а не беда.
        repository.isDirty ? .orange : .accentColor
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: GitRepository.isDetached(branch)
                  ? "point.3.connected.trianglepath.dotted"
                  : "point.topleft.down.to.point.bottomright.curvepath")
                .imageScale(.small)

            Text(branch)
                .lineLimit(1)
                // По центру: начало говорит о типе ветки, конец — о номере
                // задачи, а середина у длинных имён всегда одна и та же.
                .truncationMode(.middle)
                .font(.system(size: 11, design: .monospaced))

            if repository.isDirty {
                // Точка остаётся рядом с числом: она дублирует цвет, а
                // различение состояния по одному оттенку отсекает тех, кто его
                // не видит. Голое число такой подсказкой не служит.
                Circle().fill(tint).frame(width: 5, height: 5)

                Text("\(repository.changedFiles)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }

            if let counters {
                Text(counters)
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.85)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                // В покое шеврон приглушён — подсказка, а не кнопка; под
                // курсором выходит в полную силу.
                .opacity(isHovered ? 1 : 0.6)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(tint.opacity(fillOpacity))
                .overlay(Capsule().stroke(tint.opacity(strokeOpacity), lineWidth: 1))
        )
        // Подъём на пиксель с тенью под курсором и продавливание при нажатии:
        // тот же жест, что у кнопок панели инструментов. Не мигание и не
        // свечение — чип стоит рядом с путём, и пульсирующий элемент
        // переманивал бы внимание при каждом переходе по папкам.
        .shadow(color: .black.opacity(isHovered && !isPressed ? 0.22 : 0), radius: 3, y: 1)
        .scaleEffect(isPressed ? 0.97 : 1)
        .offset(y: isHovered && !isPressed ? -1 : 0)
        .animation(.easeOut(duration: 0.13), value: isHovered)
        .animation(.easeOut(duration: 0.13), value: isPressed)
        // Верхняя граница шире, чем у чипа в списке: адресная строка не сжата
        // колонкой, и обрезать здесь имя раньше времени незачем.
        .frame(maxWidth: 260)
    }

    private var fillOpacity: Double {
        if isPressed { return 0.30 }
        return isHovered ? 0.22 : 0.12
    }

    private var strokeOpacity: Double {
        if isPressed { return 0.70 }
        return isHovered ? 0.55 : 0.30
    }

    private var counters: String? {
        var parts: [String] = []
        if let ahead = repository.ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind = repository.behind, behind > 0 { parts.append("↓\(behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
