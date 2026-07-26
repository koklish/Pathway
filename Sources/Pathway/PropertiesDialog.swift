import AppKit
import PathwayCore
import SwiftUI

/// Диалог «Свойства»: окно наблюдения за выделенным. Только чтение. Размер
/// папки и группы считается фоном с прогрессом; счётчик живёт вместе с листом
/// (start на .onAppear, cancel на .onDisappear).
struct PropertiesDialogView: View {
    let subject: PropertiesSubject
    let dismiss: () -> Void

    @StateObject private var counter = DirectorySizeCounter()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 10) {
                switch subject {
                case let .single(props): singleFields(props)
                case let .group(props): groupFields(props)
                }
            }

            footer
        }
        .padding(28)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: startCounting)
        .onDisappear { counter.cancel() }
    }

    // MARK: - Заголовок

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch subject {
        case let .single(props): props.name
        case let .group(props): "Выделено объектов: \(props.count)"
        }
    }

    private var subtitle: String {
        switch subject {
        case let .single(props): props.kind
        case let .group(props): props.kinds
        }
    }

    /// Крупная иконка. Для одного элемента — настоящая иконка файла с диска
    /// (вызов разовый, кэш IconCache здесь не нужен). Для группы — общий значок.
    private var icon: NSImage {
        let image: NSImage
        switch subject {
        case let .single(props):
            image = NSWorkspace.shared.icon(forFile: props.url.path)
        case .group:
            image = NSWorkspace.shared.icon(for: .item)
        }
        image.size = NSSize(width: 48, height: 48)
        return image
    }

    // MARK: - Поля одного элемента

    @ViewBuilder
    private func singleFields(_ props: FileProperties) -> some View {
        row("Тип", props.kind)
        row("Расположение", props.location)
        row("Размер", singleSizeText(props))
        if props.isDirectory {
            row("Содержимое", contentsText)
        }
        Divider().padding(.vertical, 2)
        row("Создан", props.created ?? "—")
        row("Изменён", props.modified ?? "—")
        row("Доступ", props.access)
    }

    /// Размер одного элемента. Для файла — сразу из immediateSize. Для папки —
    /// растущий итог обхода, с многоточием, пока счётчик не закончил.
    private func singleSizeText(_ props: FileProperties) -> String {
        if let size = props.immediateSize {
            return byteText(size)
        }
        let base = byteText(counter.progress.totalSize)
        return counter.isFinished ? base : base + " …"
    }

    // MARK: - Поля группы

    @ViewBuilder
    private func groupFields(_ props: GroupProperties) -> some View {
        row("Расположение", props.location)
        row("Типы", props.kinds)
        row("Размер", groupSizeText)
        row("Содержимое", contentsText)
    }

    private var groupSizeText: String {
        let base = byteText(counter.progress.totalSize)
        return counter.isFinished ? base : base + " …"
    }

    /// «12 объектов (файлов: 8, папок: 4)» — растёт по мере обхода.
    private var contentsText: String {
        let p = counter.progress
        let total = p.fileCount + p.folderCount
        let suffix = counter.isFinished ? "" : " …"
        return "\(objectsWord(total)) (файлов: \(p.fileCount), папок: \(p.folderCount))\(suffix)"
    }

    // MARK: - Подвал

    private var footer: some View {
        HStack {
            if isCounting && !counter.isFinished {
                ProgressView()
                    .controlSize(.small)
                Text("Подсчёт размера…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: dismiss) {
                Text("Готово")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor)
                    }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 24)
    }

    // MARK: - Подсчёт

    /// Считаем, только если среди субъекта есть папка: у одиночного файла размер
    /// уже известен.
    private var isCounting: Bool {
        switch subject {
        case let .single(props): props.isDirectory
        case .group: true
        }
    }

    private func startCounting() {
        guard isCounting else { return }
        switch subject {
        case let .single(props): counter.start(roots: [props.url])
        case let .group(props): counter.start(roots: props.urls)
        }
    }

    // MARK: - Оформление

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func byteText(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Правильная форма слова «объект» для русского числа.
    private func objectsWord(_ n: Int) -> String {
        let mod100 = n % 100
        let mod10 = n % 10
        let word: String
        if mod100 >= 11 && mod100 <= 14 {
            word = "объектов"
        } else if mod10 == 1 {
            word = "объект"
        } else if mod10 >= 2 && mod10 <= 4 {
            word = "объекта"
        } else {
            word = "объектов"
        }
        return "\(n) \(word)"
    }
}
