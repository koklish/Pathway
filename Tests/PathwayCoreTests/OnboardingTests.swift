import Foundation
import Testing

@testable import PathwayCore

@Suite("Онбординг")
@MainActor
struct OnboardingTests {
    /// Каждому тесту — свой чистый UserDefaults, иначе они видят чужие записи.
    private func makeDefaults() -> UserDefaults {
        let suite = "onboarding.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Первый запуск

    @Test("первый запуск открывает тур с приветствия и ставит флаг")
    func firstLaunchStartsAndMarksShown() {
        let defaults = makeDefaults()
        let model = OnboardingModel(defaults: defaults)

        model.startIfFirstLaunch()

        #expect(model.currentStep == .welcome)
        #expect(defaults.bool(forKey: "onboarding.shown"))
    }

    @Test("при установленном флаге тур не открывается — обновление не показывает его повторно")
    func doesNotStartWhenAlreadyShown() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "onboarding.shown")
        let model = OnboardingModel(defaults: defaults)

        model.startIfFirstLaunch()

        #expect(model.currentStep == nil)
    }

    @Test("второй экземпляр на том же UserDefaults тур не открывает — флаг общий")
    func flagIsSharedAcrossInstances() {
        let defaults = makeDefaults()
        OnboardingModel(defaults: defaults).startIfFirstLaunch()

        let second = OnboardingModel(defaults: defaults)
        second.startIfFirstLaunch()

        #expect(second.currentStep == nil)
    }

    // MARK: - Ручной запуск

    @Test("ручной запуск открывает тур даже при установленном флаге и его не трогает")
    func manualStartIgnoresFlag() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "onboarding.shown")
        let model = OnboardingModel(defaults: defaults)

        model.start()

        #expect(model.currentStep == .welcome)
        // Флаг остался установленным, ручной запуск его не переписывал в false.
        #expect(defaults.bool(forKey: "onboarding.shown"))
    }

    @Test("ручной запуск на чистом профиле флаг не ставит")
    func manualStartDoesNotSetFlag() {
        let defaults = makeDefaults()
        let model = OnboardingModel(defaults: defaults)

        model.start()

        #expect(model.currentStep == .welcome)
        #expect(!defaults.bool(forKey: "onboarding.shown"))
    }

    // MARK: - Навигация

    @Test("next идёт по шагам по порядку")
    func nextAdvancesInOrder() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.start()

        #expect(model.currentStep == .welcome)
        model.next(); #expect(model.currentStep == .addressBar)
        model.next(); #expect(model.currentStep == .sidebar)
        model.next(); #expect(model.currentStep == .connectServer)
        model.next(); #expect(model.currentStep == .updates)
        model.next(); #expect(model.currentStep == .done)
    }

    @Test("next на последнем шаге завершает тур")
    func nextOnLastStepFinishes() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.start()
        for _ in OnboardingStep.allCases { model.next() }

        #expect(model.currentStep == nil)
    }

    @Test("back возвращается на шаг назад")
    func backGoesToPreviousStep() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.start()
        model.next()
        model.next()
        #expect(model.currentStep == .sidebar)

        model.back()

        #expect(model.currentStep == .addressBar)
    }

    @Test("back на первом шаге остаётся на приветствии")
    func backOnFirstStepStays() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.start()

        model.back()

        #expect(model.currentStep == .welcome)
    }

    @Test("skip завершает тур с любого шага")
    func skipFinishesFromAnyStep() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.start()
        model.next()
        model.next()

        model.skip()

        #expect(model.currentStep == nil)
    }

    // MARK: - Шаги

    @Test("у каждого шага непустые заголовок и текст")
    func everyStepHasContent() {
        for step in OnboardingStep.allCases {
            #expect(!step.title.isEmpty)
            #expect(!step.body.isEmpty)
        }
    }

    @Test("цель шага соответствует ожидаемой")
    func stepTargetsMatch() {
        #expect(OnboardingStep.welcome.target == .none)
        #expect(OnboardingStep.addressBar.target == .addressBar)
        #expect(OnboardingStep.sidebar.target == .sidebar)
        #expect(OnboardingStep.connectServer.target == .connectServer)
        #expect(OnboardingStep.updates.target == .versionChip)
        #expect(OnboardingStep.done.target == .none)
    }
}
