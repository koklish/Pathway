import PathwayCore
import SwiftUI

/// Статус-бар: сколько папок и файлов, что выделено, прогресс операции,
/// ползунок масштаба списка.
struct StatusBarView: View {
    let model: BrowserModel
    @Bindable var appState: AppState

    var body: some View {
        HStack {
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if let progress = model.operationProgress {
                if let title = model.operationTitle {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Button {
                    model.cancelOperation()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Отменить операцию")
            } else {
                // Только когда операции нет: прогресс с кнопкой отмены и
                // ползунок вместе не помещаются, а на узком окне ползунок
                // выдавил бы отмену за край — и прервать копирование стало бы
                // нечем. Масштаб подождёт, отмена ждать не может.
                ScaleSlider(scale: $appState.scale)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Ползунок масштаба со значками «мельче» и «крупнее» по краям.
private struct ScaleSlider: View {
    @Binding var scale: ListScale

    var body: some View {
        HStack(spacing: 6) {
            icon(size: 9)
            Slider(
                value: Binding(
                    get: { Double(scale.rawValue) },
                    // Промежуточных значений у шкалы нет, но Slider ведёт
                    // ручку в Double и на дробном шаге отдаёт .5 — округляем,
                    // иначе init(rawValue:) вернул бы nil и ступень не сменилась.
                    set: { scale = ListScale(rawValue: Int($0.rounded())) ?? scale }
                ),
                in: 0...Double(ListScale.allCases.count - 1),
                // Шаг в ступень, а не плавно: ручка щёлкает по значениям, и
                // промежуточного размера иконки не бывает вовсе.
                step: 1
            )
            .controlSize(.mini)
            .frame(width: 96)
            .help("Размер элементов списка: \(scale.title)")
            icon(size: 13)
        }
    }

    /// Значок-ориентир у края шкалы. Квадрат, а не буквы «А»: шкала меняет
    /// размер всей строки, а не только шрифта.
    private func icon(size: CGFloat) -> some View {
        Image(systemName: "square.fill")
            .font(.system(size: size * 0.72))
            .foregroundStyle(.tertiary)
            .frame(width: size, height: size)
    }
}
