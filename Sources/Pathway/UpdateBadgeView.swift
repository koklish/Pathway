import AppKit
import PathwayCore
import SwiftUI

/// Версия приложения в правом углу строки заголовка. Клик открывает поповер, где
/// живёт всё остальное: проверка, заметки к выпуску, загрузка и перезапуск.
///
/// Место выбрано так, чтобы номер версии был всегда на виду — вопрос «какая у
/// меня версия» возникает у коллег чаще, чем открывается «О программе».
///
/// Чип **не меняет содержимое по состоянию**: всегда номер версии, и только
/// точка справа появляется, когда есть новость. Раньше здесь же рисовались
/// крутилка, проценты загрузки и кнопка «Перезапустить» — шесть состояний в
/// одной капсуле тулбара. Каждое требовало своей ширины, соседние элементы
/// строки заголовка дёргались на каждом шаге загрузки, а прочитать «85 %» в
/// капсуле шириной с номер версии всё равно было негде. Всё это переехало в
/// поповер, где для текста есть место; чипу осталась одна работа — сказать, что
/// стоит заглянуть.
struct UpdateBadgeView: View {
    @Bindable var service: UpdateService

    var body: some View {
        // Поповер показывает NSPopover через AppKit, а не SwiftUI .popover.
        // Причина установлена по логу: SwiftUI-.popover, повешенный на
        // содержимое ToolbarItem, открывался и через ~40 мс схлопывался сам —
        // независимо от состояния сервиса (мигало и на неизменном .upToDate).
        // ToolbarItem в SwiftUI пересоздаётся сразу после открытия (смена
        // фокуса/keyWindow перестраивает toolbar-контент), вью-якорь
        // презентации при этом гибнет, и SwiftUI откатывает isPresented в
        // false. NSPopover держится за NSView чипа, а не за SwiftUI-обёртку, и
        // переживает эту перестройку.
        BadgeChipHost(chip: { chip }, popover: { UpdatePopoverContent(service: service) }) {
            // Клик — это и есть просьба проверить: человек открыл поповер
            // именно затем, чтобы узнать про обновления. Проверка не
            // запускается поверх уже идущей работы — сервис отсекает такое
            // сам, но и состояния с готовым ответом трогать незачем: из
            // .available повторная проверка стёрла бы найденный релиз.
            switch service.state {
            case .idle, .upToDate, .failed:
                Task { await service.checkManually() }
            default:
                break
            }
        }
        .fixedSize()
        .help(helpText)
    }

    // MARK: - Чип

    /// Капсула с номером версии. Геометрия одна на все состояния, поэтому
    /// ширина в тулбаре не скачет: меняется только наличие точки, а она сидит в
    /// потоке и занимает своё место заранее.
    private var chip: some View {
        HStack(spacing: 6) {
            Text(service.currentVersion.description)
                // Моноширинные цифры: номер версии — это цифры, и в
                // пропорциональном начертании «1.0.3» и «1.1.0» разной ширины,
                // отчего капсула дёргалась бы при обновлении.
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if hasNews {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .contentShape(Capsule())
        // Значение — само состояние: появление точки и есть повод для анимации.
        .animation(.easeOut(duration: 0.2), value: hasNews)
    }

    /// Есть ли то, ради чего стоит открыть поповер. Загрузка сюда не входит
    /// намеренно: её человек запустил сам и знает о ней, а точка — приглашение
    /// заглянуть, а не индикатор занятости.
    private var hasNews: Bool {
        switch service.state {
        case .available, .readyToRestart: true
        default: false
        }
    }

    private var helpText: String {
        switch service.state {
        case .idle, .upToDate:
            "Версия \(service.currentVersion.description). Нажмите, чтобы проверить обновления."
        case .checking:
            "Проверяю обновления…"
        case .available(let release):
            "Доступна версия \(release.version.description)."
        case .downloading(let release, _):
            "Загружаю версию \(release.version.description)…"
        case .readyToRestart(let release, _):
            "Версия \(release.version.description) готова к установке."
        case .failed(let message, _):
            message
        }
    }
}

// MARK: - Содержимое поповера

/// Три зоны: шапка с названием приложения, тело по состоянию и подвал с датой
/// последней проверки.
///
/// Отдельный `View`-тип, а не замыкание, отдающее `AnyView`, — по необходимости,
/// а не для красоты. `NSHostingController` перерисовывается на изменение
/// `@Observable` только если наблюдаемое читается в `body` его `rootView`.
/// Снимок `AnyView(popoverContent)`, снятый один раз в момент показа, стирал
/// тип и обрывал наблюдение: поповер застывал на «Проверяю…», а после проверки
/// не оживал — состояние менялось, а дерево внутри `AnyView` о нём не знало.
/// Здесь `service` читается прямо в `body` этой структуры, и хостинг-контроллер
/// подписывается на его изменения сам.
///
/// Шапка и подвал рисуются всегда, а меняется только тело — поповер при смене
/// состояния не пересобирается целиком, и переход «доступно → загрузка →
/// готово» читается как продолжение одного разговора, а не как три разных окна.
struct UpdatePopoverContent: View {
    @Bindable var service: UpdateService

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stateBody(for: service.state)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(width: 320)
        .animation(.easeOut(duration: 0.2), value: service.state)
    }

    private var header: some View {
        HStack(spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(appName)
                    .font(.headline)
                Text("Текущая версия \(service.currentVersion.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// Иконка приложения, а не SF Symbol: в шапке она подтверждает, что поповер
    /// говорит именно об этом приложении. `applicationIconImage` берёт ту же
    /// картинку, что видна в Dock, поэтому отдельного ассета не нужно.
    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApp?.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 40, height: 40)
        } else {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 40, height: 40)
        }
    }

    /// Имя из Info.plist, а не строковый литерал: внутреннее имя продукта —
    /// Pathway, а пользователю везде видно «Проводник», и второй копии этого
    /// названия в коде быть не должно.
    private var appName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? "Проводник"
    }

    // MARK: - Тело поповера

    @ViewBuilder
    private func stateBody(for state: UpdateState) -> some View {
        switch state {
        // Ещё не проверяли. Открытие поповера проверку запускает, так что это
        // состояние живёт доли секунды — но нарисовать его надо: пустое место
        // на месте тела схлопнуло бы поповер и тут же развернуло обратно.
        case .idle, .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Проверяю обновления…")
                    .font(.callout)
            }

        case .upToDate:
            statusRow(
                icon: "checkmark.circle.fill",
                tint: .green,
                text: "Установлена последняя версия"
            )

        case .available(let release):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                    Text("Доступна версия ") + Text(release.version.description).bold()
                }
                .font(.callout)

                notesList(for: release)

                Button {
                    Task { await service.download() }
                } label: {
                    Label("Загрузить и установить", systemImage: "arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

        case .downloading(let release, let progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Загрузка версии \(release.version.description)…")
                    Spacer(minLength: 8)
                    Text("\(Int(progress * 100)) %")
                        .foregroundStyle(.secondary)
                        // Цифры перекатываются вместо мигания сменой кадра:
                        // сервис отдаёт прогресс шагом в процент, без перехода
                        // это сотня отдельных морганий за загрузку.
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.callout)

                ProgressView(value: progress)
            }

        case .readyToRestart(let release, _):
            VStack(alignment: .leading, spacing: 12) {
                statusRow(
                    icon: "checkmark.circle.fill",
                    tint: .green,
                    text: "Версия \(release.version.description) готова к установке"
                )

                Button {
                    service.restart()
                } label: {
                    Label("Перезапустить и установить", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

        case .failed(let message, let release):
            VStack(alignment: .leading, spacing: 12) {
                statusRow(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: "Обновление не установлено"
                )
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Повтор ведёт туда же, куда упали: есть релиз — повторяем
                // загрузку, нет — упала проверка, и повторять надо её. Развилка
                // повторяет ту, что сервис делает внутри download(). Кнопка
                // повтора проверки не рисуется: её роль играет «Проверить
                // сейчас» в подвале, и два одинаковых действия рядом заставляли
                // бы выбирать между ними на пустом месте.
                if release != nil {
                    Button("Повторить загрузку") {
                        Task { await service.download() }
                    }
                    .frame(maxWidth: .infinity)
                    .controlSize(.large)
                }
            }
        }
    }

    private func statusRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    /// Список изменений буллетами. Скролл ограничен по высоте: заметки собраны
    /// из сообщений коммитов и на крупном релизе тянутся на десятки строк —
    /// поповер вырос бы во весь экран.
    @ViewBuilder
    private func notesList(for release: ReleaseInfo) -> some View {
        let items = ReleaseNotes.parse(release.notes)
        if items.isEmpty {
            Text("Описание изменений не приложено.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(item)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
    }

    // MARK: - Подвал

    private var footer: some View {
        HStack {
            Text(lastCheckText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                Task { await service.checkManually() }
            } label: {
                Label("Проверить сейчас", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            // Проверка поверх идущей работы всё равно отсекается сервисом —
            // гасим кнопку, чтобы нажатие не выглядело сработавшим впустую.
            // .readyToRestart сюда входит наравне с загрузкой: обновление уже
            // скачано и ждёт перезапуска, и новая проверка не имеет права
            // затереть его — сервис её и не пустит.
            .disabled(isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5))
    }

    private var isBusy: Bool {
        switch service.state {
        case .checking, .downloading, .readyToRestart: true
        default: false
        }
    }

    /// «Проверено в 21:59». Пока проверок не было — так и написано: соврать
    /// временем «никогда» нечем, а пустой подвал выглядел бы как недорисованный.
    private var lastCheckText: String {
        guard let lastCheck = service.lastCheck else { return "Ещё не проверялось" }
        return "Проверено в \(lastCheck.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - AppKit-хост поповера

/// Хостирует SwiftUI-чип в `NSView` и показывает от него `NSPopover`.
///
/// SwiftUI-`.popover` на содержимом `ToolbarItem` на macOS схлопывается сам
/// через кадр после открытия: тулбар пересоздаёт своё содержимое (открытие
/// поповера меняет фокус окна, а это перестраивает toolbar-контент), вью-якорь
/// презентации гибнет, и SwiftUI откатывает `isPresented`. `NSPopover`
/// привязан к живому `NSView`, а не к SwiftUI-обёртке, поэтому переживает эту
/// перестройку. Диагностика подтвердила ровно это: `true → false` наступал
/// через ~40 мс после каждого открытия, в том числе на неизменном состоянии.
private struct BadgeChipHost<Chip: View, Popover: View>: NSViewRepresentable {
    @ViewBuilder let chip: () -> Chip
    @ViewBuilder let popover: () -> Popover
    let onOpen: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(popover: popover, onOpen: onOpen)
    }

    func makeNSView(context: Context) -> NSView {
        let host = NSHostingView(rootView: chip())
        host.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.chipHost = host

        // Отдельный контейнер: жест кликаем по нему, а не по NSHostingView —
        // так область клика совпадает с капсулой целиком, включая её отступы.
        let container = ClickThroughView()
        container.onClick = { [weak container] in
            guard let container else { return }
            context.coordinator.togglePopover(from: container)
        }
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Пересоздаём rootView чипа: NSHostingView, созданный раз в makeNSView,
        // держит снимок дерева и сам за @Observable не следит — иначе точка
        // «есть обновление» не появлялась бы, пока окно не перерисуют по другой
        // причине. SwiftUI зовёт updateNSView на изменение наблюдаемого,
        // прочитанного в representable (chip читает service), — здесь и
        // подставляем свежее дерево.
        (context.coordinator.chipHost as? NSHostingView<Chip>)?.rootView = chip()
        context.coordinator.popover = popover
        context.coordinator.onOpen = onOpen
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: () -> Popover
        var onOpen: () -> Void
        /// NSHostingView чипа — держим, чтобы обновлять его rootView из
        /// updateNSView. Тип стёрт до NSView: generic Chip в свойство класса
        /// не пробросить без лишнего параметра, а привести обратно дёшево.
        weak var chipHost: NSView?
        private var shown: NSPopover?

        init(popover: @escaping () -> Popover, onOpen: @escaping () -> Void) {
            self.popover = popover
            self.onOpen = onOpen
        }

        func togglePopover(from view: NSView) {
            if let shown, shown.isShown {
                shown.close()
                return
            }

            onOpen()

            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            // rootView — типизированный View (UpdatePopoverContent), а не
            // AnyView-снимок: NSHostingController перерисовывается на изменение
            // @Observable только когда наблюдаемое читается в body его rootView.
            // AnyView стирал тип и обрывал наблюдение — поповер застывал на
            // «Проверяю…» и оживал лишь при переоткрытии, когда снимок снимался
            // заново. С живым типом «проверка → готово» и «загрузка → готово»
            // перерисовываются прямо в открытом поповере.
            popover.contentViewController = NSHostingController(rootView: self.popover())
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            shown = popover
        }

        func popoverDidClose(_ notification: Notification) {
            shown = nil
        }
    }
}

/// `NSView`, который зовёт замыкание по клику и не даёт клику проваливаться в
/// строку заголовка под собой.
private final class ClickThroughView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    // Клик по капсуле — это действие, а не перетаскивание окна за строку
    // заголовка: без этого drag за чип таскал бы окно.
    override var mouseDownCanMoveWindow: Bool { false }
}
