import AppKit
import PathwayCore
import SwiftUI

/// Карточка выбранного коммита: сообщение, автор, хеш и список файлов.
///
/// Заменяет секцию изменений, а не добавляется третьей: панель шириной в 370
/// точек не вмещает и то, и другое, а изменения рабочего дерева к чужому
/// коммиту отношения не имеют.
struct CommitDetailView: View {
    let commit: Commit
    let files: [GitChange]
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Вернуться к изменениям (Esc)")

                Text("Коммит")
                    .font(.system(size: 12.5, weight: .semibold))

                Text(commit.shortHash)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Button {
                    // Полный хеш, а не короткий: короткий годится глазу, но в
                    // git-команду его вставляют целиком.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.hash, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Скопировать хеш")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(commit.subject)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text(commit.author)
                    Text(Self.formatter.string(from: commit.date))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

                if !commit.refs.isEmpty {
                    Text(commit.refs.map(\.name).joined(separator: " · "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 6) {
                Text("ФАЙЛЫ")
                    .font(.system(size: 10, weight: .medium))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Text("\(files.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.03))

            List(files) { file in
                HStack(spacing: 7) {
                    Text(file.status.letter)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color(file.status))
                        .frame(width: 12)

                    Text(file.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)

                    if !file.directory.isEmpty {
                        Text(file.directory)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 22)
        }
        // Esc возвращает к изменениям. Через onExitCommand, а не
        // .keyboardShortcut(.escape) на кнопке: тот перехватывает клавишу на
        // всё окно и отбирал бы её у отмены инлайн-переименования в списке
        // файлов. onExitCommand же срабатывает только когда фокус внутри
        // панели — то же решение, что у Esc в поле поиска.
        .onExitCommand(perform: onBack)
    }

    private func color(_ status: GitChange.Status) -> Color {
        switch status {
        case .modified: .orange
        case .added, .renamed: .green
        case .deleted, .conflicted: .red
        case .untracked: .secondary
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
