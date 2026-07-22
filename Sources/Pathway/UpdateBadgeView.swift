import PathwayCore
import SwiftUI

/// Версия приложения в правом углу строки заголовка. При появлении обновления
/// превращается в кнопку.
///
/// Место выбрано так, чтобы номер версии был всегда на виду — вопрос «какая у
/// меня версия» возникает у коллег чаще, чем открывается «О программе».
///
/// Все шесть состояний рисуются одной капсулой фиксированной геометрии, а не
/// каждое своей вёрсткой: значок сидит в тулбаре, и скачок ширины при переходе
/// «версия → крутилка → прогресс → Перезапустить» дёргал бы соседние элементы
/// строки заголовка. Меняется содержимое коробки, не коробка.
struct UpdateBadgeView: View {
    @Bindable var service: UpdateService
    @State private var showPopover = false

    /// Нижняя граница, а не фиксированная ширина. Жёсткие 104pt по самому
    /// длинному состоянию («Перезапустить») оставляли номер версии плавать в
    /// пустой плашке: в покое содержимого на четыре символа, а коробка на
    /// четырнадцать. Здесь капсула растёт по содержимому, а minWidth лишь не
    /// даёт ей схлопнуться настолько, чтобы соседи в тулбаре заметно поехали.
    private static let minWidth: CGFloat = 52

    var body: some View {
        capsule
            // Ошибка и доступное обновление открывают один и тот же поповер —
            // разное в нём только содержимое. Проверка по клику осталась у
            // .idle/.checking: там открывать нечего.
            .onTapGesture {
                switch service.state {
                case .available, .failed: showPopover = true
                case .idle: Task { await service.checkManually() }
                default: break
                }
            }
            .popover(isPresented: $showPopover, arrowEdge: .bottom) { popoverContent }
            // Значение — само состояние: переход между случаями и есть повод для
            // анимации. 200 мс — верх product-нормы: значок в тулбаре не должен
            // заставлять себя ждать, но и мигать сменой кадра тоже.
            .animation(.easeOut(duration: 0.2), value: service.state)
    }

    // MARK: - Капсула

    private var capsule: some View {
        content
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            // Заливка прогресса живёт в фоне самой капсулы, а не в отдельном
            // ProgressView рядом: линейный индикатор шириной 60pt читался в
            // строке заголовка как чужеродная деталь, а вместе с процентами
            // занимал две фигуры там, где до этого была одна.
            //
            // Доля ширины берётся масштабом от якоря .leading, а не замером
            // через GeometryReader: тот жадно растягивается на всё
            // предложенное место и раздувал капсулу в тулбаре до плашки,
            // видимой даже в состоянии покоя с прозрачным фоном.
            .background(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.25))
                    .scaleEffect(x: fillFraction, y: 1, anchor: .leading)
            }
        .frame(minWidth: Self.minWidth)
        .background(Capsule().fill(background))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .clipShape(Capsule())
        .contentShape(Capsule())
        .help(helpText)
    }

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .idle:
            Text(service.currentVersion.description)
                .foregroundStyle(.tertiary)

        // Отдельный кейс, а не вместе с .idle: тот же тусклый номер версии во
        // время проверки выглядел бы так, будто клик по нему ничего не
        // запускает (сервис отсекает повторный вызов guard'ом), а на деле
        // запрос к GitHub уже летит — крутилка даёт об этом знать.
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(service.currentVersion.description)
                    .foregroundStyle(.tertiary)
            }

        case .available(let release):
            Label(release.version.description, systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)

        case .downloading(let progress):
            Text("\(Int(progress * 100)) %")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                // Цифры перекатываются вместо мигания сменой кадра. Прогресс
                // сервис отдаёт шагом в процент — без перехода это сотня
                // отдельных морганий за загрузку.
                .contentTransition(.numericText())

        // Путь к подготовленному бандлу значку не нужен — он сидит в состоянии
        // ради restart(), который берёт его оттуда сам.
        case .readyToRestart:
            Button("Перезапустить") { service.restart() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)

        // Второй параметр .failed — релиз, на загрузке которого упали (см.
        // UpdateState); тексту значка он не нужен, сообщение уходит в поповер.
        // Иконка приглушённая, а не оранжевая: не достучаться до GitHub —
        // рядовое дело, и единственное цветное пятно в монохромном окне пугало
        // бы сильнее, чем повод того стоит.
        case .failed:
            Label("Не удалось", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Оформление по состоянию

    /// В покое капсула невидима — только тусклый номер версии. Фон и обводка
    /// проявляются, лишь когда значку есть что сказать: постоянная плашка в
    /// заголовке весила бы больше, чем номер версии заслуживает.
    private var background: Color {
        switch service.state {
        case .idle, .checking: .clear
        case .available, .readyToRestart: Color.accentColor.opacity(0.12)
        case .downloading, .failed: Color.primary.opacity(0.06)
        }
    }

    private var border: Color {
        switch service.state {
        case .idle, .checking: .clear
        case .available, .readyToRestart: Color.accentColor.opacity(0.35)
        case .downloading, .failed: Color.primary.opacity(0.1)
        }
    }

    private var fillFraction: CGFloat {
        if case .downloading(let progress) = service.state { return progress }
        return 0
    }

    private var helpText: String {
        switch service.state {
        case .idle:
            "Версия \(service.currentVersion.description). Нажмите, чтобы проверить обновления."
        case .checking:
            "Проверяю обновления…"
        case .available(let release):
            "Доступна версия \(release.version.description). Нажмите, чтобы посмотреть, что нового."
        case .downloading:
            "Загружаю обновление…"
        case .readyToRestart:
            "Обновление готово. Приложение закроется и откроется заново."
        case .failed(let message, _):
            message
        }
    }

    // MARK: - Поповер

    /// Заметки к релизу и кнопка загрузки в одном поповере. Раньше рядом с
    /// кнопкой обновления стоял отдельный значок «i» на 16pt, и два действия
    /// разделяла только точность попадания курсором: желавший прочитать список
    /// изменений промахивался и запускал загрузку. Здесь они разведены уровнем —
    /// сначала читаешь, потом решаешь.
    @ViewBuilder
    private var popoverContent: some View {
        switch service.state {
        case .available(let release):
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Версия \(release.version.description)")
                        .font(.headline)
                    Text("Установлена \(service.currentVersion.description)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if release.notes.isEmpty {
                    Text("Описание изменений не приложено.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(release.notes)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }

                Button {
                    showPopover = false
                    Task { await service.download() }
                } label: {
                    Text("Обновить")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(16)
            .frame(width: 320)

        case .failed(let message, let release):
            VStack(alignment: .leading, spacing: 12) {
                Text("Обновление не установлено")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Повтор ведёт туда же, куда упали: есть релиз — повторяем
                // загрузку, нет — упала проверка, и повторять надо её.
                // Развилка повторяет ту, что сервис делает внутри download().
                Button(release == nil ? "Проверить снова" : "Повторить загрузку") {
                    showPopover = false
                    Task {
                        if release == nil { await service.checkManually() }
                        else { await service.download() }
                    }
                }
                .frame(maxWidth: .infinity)
                .controlSize(.large)
            }
            .padding(16)
            .frame(width: 300)

        default:
            EmptyView()
        }
    }
}
