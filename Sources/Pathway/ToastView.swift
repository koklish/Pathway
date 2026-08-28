import PathwayCore
import SwiftUI

/// Всплывающее сообщение о результате git-операции.
///
/// Появилось потому, что об окончании обмена с сервером узнать было неоткуда:
/// строка «Получение изменений…» просто пропадала из статус-бара, и человек не
/// понимал, принёс fetch что-нибудь или сходил впустую. Алерт для этого не
/// годится — он требует нажать «ОК» ради известия, что всё хорошо.
///
/// Показывается над статус-баром, там же, где шёл прогресс: взгляд уже там,
/// а верх списка файлов остаётся не закрыт.
struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(toast.kind == .success ? Color.green : Color.orange)
            Text(toast.text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Материал, а не сплошная заливка: тост лежит поверх списка файлов, и
        // непрозрачная плашка выглядела бы вырезанным из него куском.
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .contentShape(Capsule())
        .onTapGesture(perform: onDismiss)
        // Курсор-стрелка, а не палец: тост не ссылка, клик по нему лишь
        // убирает сообщение раньше срока.
        .help("Скрыть сообщение")
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }
}
