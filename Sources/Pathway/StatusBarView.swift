import PathwayCore
import SwiftUI

/// Статус-бар: сколько папок и файлов, что выделено, прогресс операции.
struct StatusBarView: View {
    let model: BrowserModel

    var body: some View {
        HStack {
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if let progress = model.operationProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
