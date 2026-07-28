import PathwayCore
import SwiftUI

/// Поле поиска в адресной строке.
///
/// Поиск начинается по Enter, а не по мере набора. На сетевом диске — главном
/// сценарии — живой поиск шёл бы в сеть на каждую букву, отменяя предыдущий
/// обход на полпути и толкаясь в очереди; при обходе записи в ~9 мс это
/// секунды бессмысленной работы за одно слово.
struct SearchFieldView: View {
    let search: SearchModel
    let directory: URL
    @Environment(AppState.self) private var appState
    @FocusState private var focused: Bool

    /// Подсказка в пустом поле меняется вместе с режимом: иначе включённый
    /// переключатель — единственный признак того, что поиск идёт дольше
    /// обычного, и о нём легко забыть.
    private var placeholder: String {
        search.searchesContent ? "Поиск в именах и содержимом" : "Поиск в папке и архивах"
    }

    var body: some View {
        @Bindable var search = search
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { search.search(in: directory) }
                // Esc закрывает поиск и возвращает список файлов. Через
                // onExitCommand, а не .keyboardShortcut(.escape): у кнопки
                // шорткат гаснет вместе с её .disabled и не работает, пока
                // фокус в поле ввода, — а Esc нужен именно оттуда.
                .onExitCommand {
                    search.cancel()
                    focused = false
                }

            // Переключатель поиска по содержимому. Виден всегда, а не только
            // при непустом запросе: человек должен знать о возможности до того,
            // как начал набирать, — иначе о ней узнают лишь случайно.
            Button {
                search.searchesContent.toggle()
                // Перезапуск, если выдача уже есть: включить режим и смотреть на
                // старый результат — значит решить, что он не работает.
                if search.isActive, !search.activeQuery.isEmpty {
                    search.query = search.activeQuery
                    search.search(in: directory)
                }
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(search.searchesContent ? Color.white : Color.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(search.searchesContent ? Color.accentColor : Color.clear)
                    }
            }
            .buttonStyle(.plain)
            .help(search.searchesContent
                ? "Искать в содержимом файлов — включено. Поиск идёт дольше."
                : "Искать в содержимом файлов")

            // Индикатора хода здесь нет: он в строке под списком, где рядом с
            // ним стоят счётчики. Два места, показывающие одно и то же,
            // заставляли бы искать глазами, которое из них главное.
            if !search.query.isEmpty || search.isActive {
                Button {
                    search.cancel()
                    focused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Закрыть поиск (Esc)")
            }
        }
        // Отступы, высота и рамка повторяют поле пути из AddressBarView: два
        // поля стоят в одной строке, и любое расхождение читается как сбой
        // вёрстки. Значения продублированы, а не вынесены в общий модификатор:
        // держать ради двух вью третий файл дороже, чем совпадающие числа.
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            focused ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: focused ? 2 : 1
                        )
                }
        }
        // Фиксированная ширина, а не доля: иначе поле пути и поиск делили бы
        // строку поровну, и хлебные крошки схлопывались бы на глубоких путях.
        .frame(width: 260)
        // Пока фокус в поле, файловые команды гасятся: F2 и ⌘⌫ не должны
        // трогать выделенные файлы, пока человек набирает запрос. Тот же приём,
        // что в адресной строке.
        .onChange(of: focused) { _, isFocused in appState.isEditingText = isFocused }
        .onDisappear { appState.isEditingText = false }
        // ⌘F из главного меню: команда не может сфокусировать поле сама,
        // поэтому выставляет запрос, а поле его исполняет — как ⌘L у адресной
        // строки.
        .onChange(of: appState.pendingSearch) { _, pending in
            guard pending else { return }
            focused = true
            appState.pendingSearch = false
        }
    }
}
