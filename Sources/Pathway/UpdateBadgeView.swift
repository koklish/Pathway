import PathwayCore
import SwiftUI

/// Версия приложения в правом углу строки заголовка. При появлении обновления
/// превращается в кнопку.
///
/// Место выбрано так, чтобы номер версии был всегда на виду — вопрос «какая у
/// меня версия» возникает у коллег чаще, чем открывается «О программе».
struct UpdateBadgeView: View {
    @Bindable var service: UpdateService
    @State private var showNotes = false

    var body: some View {
        switch service.state {
        case .idle:
            Text(service.currentVersion.description)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
                .help("Версия \(service.currentVersion.description). Нажмите, чтобы проверить обновления.")
                .onTapGesture { Task { await service.checkManually() } }

        // Отдельный кейс, а не вместе с .idle: тот же тусклый номер версии во
        // время проверки выглядел бы так, будто клик по нему ничего не
        // запускает (сервис отсекает повторный вызов guard'ом), а на деле
        // запрос к GitHub уже летит — крутилка и другая подсказка дают об
        // этом знать.
        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(service.currentVersion.description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .help("Проверяю обновления…")

        case .available(let release):
            // Клик по самой кнопке запускает загрузку — это ожидаемое
            // поведение из состояния «доступно обновление». Заметки к
            // релизу вынесены в отдельный маленький значок рядом: если бы
            // и то, и другое читалось с одного клика по кнопке, человек,
            // просто желающий узнать что изменилось, случайно запускал бы
            // загрузку. Поповер открывается по клику на значке, а не по
            // наведению — наведение мигает, когда курсор уходит с кнопки на
            // сам поповер (см. .onHover в AddressBarView/NetworkSection/
            // ConnectServerView: там оно только подсвечивает, нигде не
            // открывает поповеры).
            HStack(spacing: 4) {
                Button {
                    Task { await service.download() }
                } label: {
                    Label(release.version.description, systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .help("Доступна версия \(release.version.description). Нажмите, чтобы обновиться.")

                Button {
                    showNotes = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Что нового в версии \(release.version.description)")
                .popover(isPresented: $showNotes, arrowEdge: .bottom) {
                    notes(release.notes, version: release.version.description)
                }
            }

        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                Text("\(Int(progress * 100)) %")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

        case .readyToRestart:
            Button("Перезапустить") { service.restart() }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .help("Обновление готово. Приложение закроется и откроется заново.")

        // Второй параметр .failed — релиз, на загрузке которого упали (см.
        // UpdateState); значку он не нужен, тут важен только текст ошибки.
        case .failed(let message, _):
            Label("Ошибка", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .contentShape(Rectangle())
                .help(message)
                .onTapGesture { Task { await service.checkManually() } }
        }
    }

    private func notes(_ text: String, version: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Версия \(version)").font(.headline)
            if text.isEmpty {
                Text("Описание изменений не приложено.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(text).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        }
        .padding()
        .frame(width: 320)
    }
}
