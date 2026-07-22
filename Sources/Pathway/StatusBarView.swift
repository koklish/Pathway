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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
