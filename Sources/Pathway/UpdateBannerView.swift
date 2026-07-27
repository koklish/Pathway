import PathwayCore
import SwiftUI

/// Баннер о доступном обновлении внизу сайдбара.
///
/// Третья дверь в тот же сценарий обновления — после точки на чипе версии и
/// системного уведомления. Появился потому, что первых двух не хватило: точка
/// диаметром 6 pt в правом верхнем углу как приглашение к действию не читается,
/// и коллеги обновлялись, только когда им говорили голосом.
///
/// Своей логики обновления здесь нет ни строки: состояние, поповер и перезапуск
/// целиком принадлежат `UpdateService`, баннер лишь называет словами то, о чём
/// чип говорит точкой.
struct UpdateBannerView: View {
    @Bindable var service: UpdateService

    /// Версия, для которой баннер закрыли крестиком. Живёт до перезапуска
    /// приложения намеренно: запись в UserDefaults помогала бы надёжнее
    /// откладывать обновление, а задача ровно обратная.
    @State private var dismissedVersion: AppVersion?

    var body: some View {
        // Divider рисуется вместе с баннером, а не всегда: под пустым местом
        // сайдбара отдельная черта выглядела бы недорисованной границей.
        if let banner = current {
            VStack(spacing: 0) {
                Divider()
                content(for: banner)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Что показывать

    /// Состояние баннера. Отдельный тип, а не разбор `UpdateState` по месту:
    /// иначе версия, текст и действие разъезжались бы по трём switch'ам.
    private struct Banner {
        let release: ReleaseInfo
        let icon: String
        let title: String
        let subtitle: String
        /// Крестик есть только у найденного обновления. Скачанное и ждущее
        /// перезапуска скрывать нельзя: оно уже заняло место на диске, и без
        /// баннера о нём не осталось бы напоминания, кроме той самой точки,
        /// недостаточность которой и породила этот баннер.
        let isDismissible: Bool
    }

    /// Те же два состояния, что зажигают точку на чипе (`UpdateBadgeView.hasNews`).
    /// Совпадение намеренное: баннер и точка обязаны появляться и исчезать
    /// вместе, иначе интерфейс противоречит сам себе.
    private var current: Banner? {
        switch service.state {
        case .available(let release):
            guard release.version != dismissedVersion else { return nil }
            return Banner(
                release: release,
                icon: "sparkles",
                title: "Доступна версия",
                subtitle: "Нажмите, чтобы посмотреть изменения",
                isDismissible: true
            )

        // Скачанное обновление — другое событие, чем найденное: приглашение
        // «посмотрите изменения» тому, кто уже нажал «Загрузить», выглядело бы
        // так, будто загрузка не удалась.
        case .readyToRestart(let release, _):
            return Banner(
                release: release,
                icon: "checkmark.circle.fill",
                title: "Готова версия",
                subtitle: "Перезапустите, чтобы установить",
                isDismissible: false
            )

        // Загрузку и проверку человек запустил сам и видит их в поповере, а
        // .failed внизу сайдбара — шум, который нечем исправить на месте.
        default:
            return nil
        }
    }

    // MARK: - Вид

    private func content(for banner: Banner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(banner.title)
                        .font(.system(size: 13))
                    // Моноширинные цифры, как в чипе версии: «1.2.0» и «1.10.0»
                    // в пропорциональном начертании разной ширины.
                    Text(banner.release.version.description)
                        .font(.system(size: 13, design: .monospaced))
                        .fontWeight(.semibold)
                }
                .lineLimit(1)

                Text(banner.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if banner.isDismissible {
                Button {
                    dismissedVersion = banner.release.version
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Скрыть до следующего выпуска")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.12))
        }
        // Вся карточка — одна кнопка, поэтому крестик приходится вынимать из
        // неё: вложенная кнопка в SwiftUI до нажатия не доходит, клик забирал бы
        // внешняя. Отсюда contentShape на HStack, а не Button вокруг всего.
        .contentShape(Rectangle())
        .onTapGesture { activate() }
    }

    /// Клик по карточке. Найденное обновление ведёт в поповер — там заметки к
    /// выпуску и кнопка загрузки; готовое ставится сразу, отправлять человека за
    /// второй такой же кнопкой незачем.
    private func activate() {
        switch service.state {
        case .readyToRestart:
            service.restart()
        default:
            service.requestPopover()
        }
    }
}
