import PathwayCore
import SwiftUI

/// Лист пакетного переименования: правила сверху, живое превью таблицей.
///
/// Превью — `BatchRenamePlan.build` на каждое изменение полей, без
/// дебаунса: движок чистый и дешёвый, а отложенный пересчёт выглядел бы
/// как неработающее правило.
struct BatchRenameSheet: View {
    let model: BrowserModel
    let items: [FileItem]
    let dismiss: () -> Void

    @State private var rule = BatchRenameRule()

    /// Шаги плана от текущих полей. Порядок items — порядок сортировки
    /// списка: человек видит номера ровно в том порядке, в котором они
    /// назначатся.
    private var steps: [RenameStep] {
        BatchRenamePlan.build(items: items, rule: rule)
    }

    private var okCount: Int {
        steps.count { $0.status == .ok }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Переименовать выбранные")
                    .font(.system(size: 20, weight: .bold))
                Text("Объектов: \(items.count) — расширения сохраняются")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)

            rulesForm

            Divider()
                .padding(.vertical, 12)

            preview
                .frame(minHeight: 180)

            footer
        }
        .padding(28)
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Правила

    private var rulesForm: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                fieldLabel("Найти")
                TextField("", text: $rule.find)
                    .textFieldStyle(.roundedBorder)
                fieldLabel("Заменить на")
                TextField("", text: $rule.replace)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                Toggle("Учитывать регистр", isOn: $rule.caseSensitive)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Color.clear.frame(width: 0, height: 0)
                Color.clear.frame(width: 0, height: 0)
            }
            GridRow {
                fieldLabel("Префикс")
                TextField("", text: $rule.prefix)
                    .textFieldStyle(.roundedBorder)
                fieldLabel("Суффикс")
                TextField("", text: $rule.suffix)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                fieldLabel("Нумерация")
                Picker("", selection: $rule.numbering) {
                    ForEach(BatchRenameRule.Numbering.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if rule.numbering != .off {
                    HStack(spacing: 8) {
                        Stepper("с \(rule.numberingStart)", value: $rule.numberingStart, in: 0...99999)
                        Stepper("шаг \(rule.numberingStep)", value: $rule.numberingStep, in: 1...100)
                        Stepper("разряды \(rule.numberingPad)", value: $rule.numberingPad, in: 1...6)
                    }
                    .font(.system(size: 12))
                    .gridCellColumns(2)
                }
            }
            GridRow {
                fieldLabel("Регистр")
                Picker("", selection: $rule.changeCase) {
                    ForEach(BatchRenameRule.ChangeCase.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .font(.system(size: 13))
    }

    // MARK: - Превью

    private var preview: some View {
        Table(steps, selection: .constant(nil as URL?)) {
            TableColumn("Имя") { step in
                Text(step.item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TableColumn("Новое имя") { step in
                switch step.status {
                case .ok:
                    Text(step.newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .conflict(let reason):
                    // Конфликт — данные плана, а не исключение в момент
                    // записи: причина видна до нажатия кнопки, а шаг при
                    // выполнении пропускается.
                    Text("\(step.newName.isEmpty ? "—" : step.newName): \(reason)")
                        .lineLimit(1)
                        .foregroundStyle(.red)
                }
            }
        }
        .font(.system(size: 12))
    }

    // MARK: - Кнопки

    private var footer: some View {
        HStack(spacing: 12) {
            if !steps.isEmpty {
                Text(okCount == steps.count
                     ? "Будет переименовано: \(okCount)"
                     : "Будет переименовано: \(okCount), конфликтов: \(steps.count - okCount)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button("Отмена", action: dismiss)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .keyboardShortcut(.cancelAction)

            // Активна, пока есть хотя бы один исполнимый шаг: нажатие при
            // нуле было бы молчаливым ничегонеделанием.
            Button(action: submit) {
                Text("Переименовать")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(okCount > 0 ? Color.accentColor : Color.accentColor.opacity(0.5))
                    }
            }
            .buttonStyle(.plain)
            .disabled(okCount == 0)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 16)
    }

    private func submit() {
        guard okCount > 0 else { return }
        model.applyBatchRename(steps)
        dismiss()
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
    }
}
