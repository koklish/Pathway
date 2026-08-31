import Foundation
import Testing

@testable import PathwayCore

@Suite("Масштаб списка файлов")
@MainActor
struct ListScaleTests {
    /// Каждому тесту — свой чистый UserDefaults, иначе они видят чужие записи.
    private func makeDefaults() -> UserDefaults {
        let suite = "listscale.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: - Шкала

    @Test("умолчание совпадает с нынешним видом списка: иконка 16, строка 24")
    func defaultMatchesCurrentAppearance() {
        #expect(ListScale.default.iconSize == 16)
        #expect(ListScale.default.rowHeight == 24)
    }

    @Test("иконка растёт от ступени к ступени, от 14 до 48")
    func iconGrowsMonotonically() {
        let sizes = ListScale.allCases.map(\.iconSize)
        #expect(sizes == [14, 16, 24, 32, 48])
        #expect(sizes == sizes.sorted())
    }

    @Test("высота строки — иконка плюс постоянный воздух, а не множитель")
    func rowHeightAddsConstantPadding() {
        for scale in ListScale.allCases {
            #expect(scale.rowHeight == scale.iconSize + 8)
        }
    }

    @Test("шрифт растёт медленнее иконки: втрое больший значок не даёт втрое больший текст")
    func fontGrowsSlowerThanIcon() {
        let compact = ListScale.compact
        let huge = ListScale.huge
        let iconRatio = huge.iconSize / compact.iconSize
        let fontRatio = huge.fontSize / compact.fontSize
        #expect(fontRatio < iconRatio)
    }

    @Test("шрифт растёт от ступени к ступени, без повторов")
    func fontGrowsMonotonically() {
        let sizes = ListScale.allCases.map(\.fontSize)
        #expect(sizes == sizes.sorted())
        #expect(Set(sizes).count == sizes.count)
    }

    @Test("заголовок колонки мельче содержимого на каждой ступени")
    func headerIsSmallerThanContent() {
        for scale in ListScale.allCases {
            #expect(scale.headerFontSize < scale.fontSize)
        }
    }

    @Test("на обычной ступени ширина колонок не трогается")
    func normalScaleKeepsColumnWidths() {
        // Ширины подобраны под нынешний кегль: доработка не вправе сдвинуть их
        // тем, кто ползунок не трогал.
        #expect(ListScale.default.columnWidthFactor == 1)
        #expect(ListScale.default.nameColumnExtraWidth == 0)
    }

    @Test("колонки расширяются вслед за шрифтом, иначе дата обрезалась бы")
    func columnsWidenWithFont() {
        for scale in ListScale.allCases where scale.fontSize > ListScale.default.fontSize {
            #expect(scale.columnWidthFactor > 1)
        }
    }

    @Test("колонка имени получает добавку на иконку, остальные — нет")
    func onlyNameColumnGetsIconAllowance() {
        // Значок рисует только колонка имени: растить остальные на его ширину
        // значило бы отдавать место впустую.
        #expect(ListScale.huge.nameColumnExtraWidth == ListScale.huge.iconSize - 16)
        #expect(ListScale.compact.nameColumnExtraWidth < 0)
    }

    @Test("шаг по шкале даёт соседнюю ступень")
    func stepMovesToNeighbour() {
        #expect(ListScale.normal.stepped(by: 1) == .medium)
        #expect(ListScale.normal.stepped(by: -1) == .compact)
    }

    @Test("шаг за край шкалы даёт nil, а не саму ступень")
    func stepBeyondEdgeReturnsNil() {
        #expect(ListScale.huge.stepped(by: 1) == nil)
        #expect(ListScale.compact.stepped(by: -1) == nil)
    }

    // MARK: - Хранение

    @Test("выбранный масштаб переживает перезапуск")
    func scaleSurvivesRestart() {
        let defaults = makeDefaults()
        TabsStore(defaults: defaults).save(scale: .large)

        #expect(TabsStore(defaults: defaults).restoreScale() == .large)
    }

    @Test("без сохранённого значения масштаб — обычный, а не компактный")
    func missingKeyGivesDefaultNotCompact() {
        // rawValue компактной ступени равен нулю, и integer(forKey:) отдал бы
        // именно его на отсутствующем ключе: список сам собой сжался бы при
        // первом запуске новой версии у всех, кто ползунок не трогал.
        let restored = TabsStore(defaults: makeDefaults()).restoreScale()

        #expect(restored == .default)
        #expect(restored != .compact)
    }

    @Test("явно выбранный компактный отличим от отсутствующего ключа")
    func explicitCompactIsDistinguishableFromMissingKey() {
        let defaults = makeDefaults()
        TabsStore(defaults: defaults).save(scale: .compact)

        #expect(TabsStore(defaults: defaults).restoreScale() == .compact)
    }

    @Test("незнакомая ступень из чужой версии сводится к умолчанию")
    func unknownRawValueFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set(99, forKey: "list.scale")

        #expect(TabsStore(defaults: defaults).restoreScale() == .default)
    }

    // MARK: - Область действия

    @Test("масштаб общий для всех вкладок, а не свой у каждой")
    func scaleIsSharedAcrossTabs() {
        let model = TabsModel(path: home, store: TabsStore(defaults: makeDefaults()))
        model.open(home, activate: false)
        model.scale = .huge

        // Значение живёт в одном месте, поэтому любая вкладка видит именно его.
        #expect(model.scale == .huge)
        #expect(model.tabs.count == 2)
    }

    @Test("смена масштаба сохраняется сразу, без ожидания закрытия приложения")
    func changeIsPersistedImmediately() {
        let defaults = makeDefaults()
        let model = TabsModel(path: home, store: TabsStore(defaults: defaults))

        model.scale = .medium

        #expect(TabsStore(defaults: defaults).restoreScale() == .medium)
    }

    @Test("запуск поднимает сохранённый масштаб")
    func startupRestoresSavedScale() {
        let defaults = makeDefaults()
        TabsStore(defaults: defaults).save(scale: .large)

        let model = TabsModel(path: home, store: TabsStore(defaults: defaults))

        #expect(model.scale == .large)
    }

    @Test("AppState отдаёт масштаб из TabsModel, а не держит свою копию")
    func appStateProxiesToTabsModel() {
        let tabs = TabsModel(path: home, store: TabsStore(defaults: makeDefaults()))
        let state = AppState(tabs: tabs)

        state.scale = .huge

        #expect(tabs.scale == .huge)
        #expect(state.scale == .huge)
    }
}
