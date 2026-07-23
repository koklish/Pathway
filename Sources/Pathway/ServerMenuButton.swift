import PathwayCore
import SwiftUI

/// Кнопка серверов в тулбаре, слева от «?». Центр управления сетью, когда
/// секцию «Сеть» в сайдбаре оттеснило вниз большое дерево папок.
///
/// Меню строится в две секции: сверху — подключённые тома (переход одним
/// нажатием), ниже — сохранённые, но сейчас отключённые серверы (подключить и
/// перейти). Внизу — вход в диалог нового подключения. Пока хоть один том
/// смонтирован, на капсуле горит зелёная точка — тот же язык, что у строки
/// сервера в сайдбаре: сеть на связи видно, не открывая меню.
///
/// Оформлена той же капсулой, что «?» и значок версии: капсула и паддинги
/// живут внутри label (снаружи Menu добавил бы собственную высоту контрола и
/// капсула раздулась бы), метрика совпадает с соседями до пикселя.
struct ServerMenuButton: View {
    @Bindable var connection: ServerConnection
    /// Открыть диалог нового подключения.
    let onNewConnection: () -> Void
    /// Перейти к серверу: смонтированный — сразу, иначе подключить и перейти.
    let onOpen: (ServerAddress) -> Void

    var body: some View {
        // Обычное Menu без primaryAction: клик по капсуле раскрывает список.
        // primaryAction превратил бы кнопку в split-button (основная зона +
        // зона-стрелка), а .menuIndicator(.hidden) убрал бы стрелку — и тогда
        // раскрыть меню было бы негде, любой клик уходил бы в primaryAction.
        // «Подключиться к серверу…» живёт пунктом внутри меню, не как основное
        // действие кнопки.
        Menu {
            menuContent
        } label: {
            capsule
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Серверы: подключиться или перейти к подключённому")
    }

    // MARK: - Капсула

    private var capsule: some View {
        Image(systemName: "externaldrive")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 13)
            // Зелёная точка поверх иконки — есть подключённые тома. Overlay, а не
            // соседний элемент: ширина капсулы должна совпадать с «?», точка не
            // должна её расширять.
            .overlay(alignment: .topTrailing) {
                if hasConnected {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                        .offset(x: 3, y: -2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.2), value: hasConnected)
    }

    // MARK: - Содержимое меню

    @ViewBuilder
    private var menuContent: some View {
        let connected = connectedEntries
        let saved = savedEntries

        if connected.isEmpty && saved.isEmpty {
            // Заглушка вместо пустоты: пункт, который ничего не делает, честнее
            // отсутствия секции — иначе меню выглядело бы обрезанным.
            Text("Нет серверов")
        }

        if !connected.isEmpty {
            Section("Подключены") {
                ForEach(connected) { entry in
                    Button {
                        onOpen(entry.server)
                    } label: {
                        MenuLabel(entry.name, symbol: "externaldrive.fill.badge.checkmark",
                                  color: .controlAccentColor)
                    }
                }
            }
        }

        if !saved.isEmpty {
            Section("Сохранённые") {
                ForEach(saved) { entry in
                    Button {
                        onOpen(entry.server)
                    } label: {
                        MenuLabel(entry.name, symbol: "externaldrive", color: .secondaryLabelColor)
                    }
                }
            }
        }

        Divider()

        Button {
            onNewConnection()
        } label: {
            MenuLabel("Подключиться к серверу…", symbol: "externaldrive.badge.plus", color: .systemBlue)
        }
    }

    // MARK: - Данные

    private var hasConnected: Bool { !connection.mounted.networkVolumes.isEmpty }

    /// Подключённые тома: закладки и тома, смонтированные мимо приложения
    /// (через Finder), дедуплицированные по адресу — как в сайдбаре.
    private var connectedEntries: [ServerMenuEntry] {
        connection.mounted.networkVolumes.map {
            ServerMenuEntry(server: $0.server, name: $0.name)
        }
    }

    /// Сохранённые, но сейчас не подключённые серверы.
    private var savedEntries: [ServerMenuEntry] {
        let mountedKeys = Set(connection.mounted.networkVolumes.map(\.server.key))
        return connection.bookmarks.items.compactMap { bookmark in
            guard let server = bookmark.server, !mountedKeys.contains(server.key) else { return nil }
            return ServerMenuEntry(server: server, name: bookmark.name)
        }
    }
}

/// Одна строка меню серверов: адрес для действия, имя для показа.
private struct ServerMenuEntry: Identifiable {
    let server: ServerAddress
    let name: String
    var id: String { server.key }
}
