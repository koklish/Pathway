import Foundation
import Testing

@testable import PathwayCore

@Suite("Ширины колонок списка файлов")
@MainActor
struct ColumnWidthsTests {
    /// Каждому тесту — свой чистый UserDefaults, иначе они видят чужие записи.
    private func makeDefaults() -> UserDefaults {
        let suite = "columnwidths.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Хранение значений

    @Test("умолчание пусто: ни одна колонка не считается настроенной")
    func defaultIsEmpty() {
        let widths = ColumnWidths.default
        #expect(widths.width(for: "name") == nil)
        #expect(widths.isCustomized("name") == false)
    }

    @Test("настроенная колонка отдаёт свою ширину")
    func storesWidth() {
        var widths = ColumnWidths()
        widths.set(320, for: "name")
        #expect(widths.width(for: "name") == 320)
        #expect(widths.isCustomized("name"))
    }

    @Test("колонки независимы: настройка одной не трогает соседние")
    func columnsAreIndependent() {
        var widths = ColumnWidths()
        widths.set(320, for: "name")
        #expect(widths.isCustomized("size") == false)
        #expect(widths.width(for: "size") == nil)
    }

    // MARK: - Границы разумного

    @Test("ширина ниже минимума отбрасывается, а не схлопывает колонку")
    func rejectsTooNarrow() {
        var widths = ColumnWidths()
        widths.set(10, for: "name")
        #expect(widths.width(for: "name") == nil)
    }

    @Test("ширина ровно в минимум принимается: граница включительна")
    func acceptsExactMinimum() {
        var widths = ColumnWidths()
        widths.set(ColumnWidths.minimum, for: "name")
        #expect(widths.width(for: "name") == ColumnWidths.minimum)
    }

    @Test("ширина больше разумного максимума отбрасывается")
    func rejectsTooWide() {
        var widths = ColumnWidths()
        widths.set(5000, for: "name")
        #expect(widths.width(for: "name") == nil)
    }

    @Test("NaN отбрасывается, а не проходит проверку диапазона")
    func rejectsNaN() {
        var widths = ColumnWidths()
        widths.set(.nan, for: "name")
        #expect(widths.width(for: "name") == nil)
    }

    @Test("бесконечность отбрасывается")
    func rejectsInfinity() {
        var widths = ColumnWidths()
        widths.set(.infinity, for: "name")
        #expect(widths.width(for: "name") == nil)
    }

    @Test("негодные значения отсеиваются и при создании из словаря")
    func filtersOnInit() {
        let widths = ColumnWidths(["name": 300, "size": 5, "kind": 9000])
        #expect(widths.width(for: "name") == 300)
        #expect(widths.width(for: "size") == nil)
        #expect(widths.width(for: "kind") == nil)
    }

    // MARK: - Сохранение между запусками

    @Test("ширины переживают перезапуск")
    func survivesRestart() {
        let defaults = makeDefaults()
        var widths = ColumnWidths()
        widths.set(320, for: "name")
        widths.set(200, for: "modified")
        TabsStore(defaults: defaults).save(columnWidths: widths)

        let restored = TabsStore(defaults: defaults).restoreColumnWidths()
        #expect(restored.width(for: "name") == 320)
        #expect(restored.width(for: "modified") == 200)
    }

    @Test("пустое хранилище даёт умолчание, а не пустые колонки")
    func emptyStorageGivesDefault() {
        let restored = TabsStore(defaults: makeDefaults()).restoreColumnWidths()
        #expect(restored == .default)
    }

    @Test("испорченная запись сводится к умолчанию, а не роняет разбор")
    func ignoresGarbage() {
        let defaults = makeDefaults()
        defaults.set(["name": "широкая"], forKey: "columns.widths")
        #expect(TabsStore(defaults: defaults).restoreColumnWidths() == .default)
    }

    @Test("негодная ширина из хранилища отсеивается при чтении")
    func filtersGarbageWidthOnRestore() {
        let defaults = makeDefaults()
        defaults.set(["name": 300.0, "size": 3.0], forKey: "columns.widths")
        let restored = TabsStore(defaults: defaults).restoreColumnWidths()
        #expect(restored.width(for: "name") == 300)
        #expect(restored.width(for: "size") == nil)
    }

    // MARK: - Связь с моделью вкладок

    @Test("запись ширины в модель сохраняется в хранилище")
    func modelSavesWidth() {
        let defaults = makeDefaults()
        let model = TabsModel(store: TabsStore(defaults: defaults), makeWatcher: { FakeDirectoryWatcher() })
        model.setColumnWidth(340, for: "name")

        #expect(TabsStore(defaults: defaults).restoreColumnWidths().width(for: "name") == 340)
    }

    @Test("модель поднимает сохранённые ширины при запуске")
    func modelRestoresWidths() {
        let defaults = makeDefaults()
        var widths = ColumnWidths()
        widths.set(340, for: "name")
        TabsStore(defaults: defaults).save(columnWidths: widths)

        let model = TabsModel(store: TabsStore(defaults: defaults), makeWatcher: { FakeDirectoryWatcher() })
        #expect(model.columnWidths.width(for: "name") == 340)
    }
}
