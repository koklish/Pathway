import PathwayCore
import SwiftUI

/// Кнопка «?» слева от значка версии. Запускает обучающий тур заново.
///
/// Оформлена той же капсулой, что и `UpdateBadgeView`: капсула-подложка со
/// своим фоном и рамкой, без стеклянной подложки тулбара macOS 26. Так «?» и
/// номер версии выглядят одной парой, а не разнородными кнопками.
struct HelpBadgeView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Знак вопроса без обводки: обводку даёт капсула, как у чипа версии
            // её даёт не глиф, а фон. Иначе получился бы кружок внутри капсулы.
            Image(systemName: "questionmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                // Ширина под глиф, чтобы капсула была круглой, а не сплюснутой.
                .frame(minWidth: 13)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Показать обучение")
    }
}
