import PathwayCore
import SwiftUI

// MARK: - Сбор координат целей

/// Якоря подсвечиваемых элементов окна, собранные из дочерних вью.
///
/// Каждый элемент помечает себя `.onboardingTarget(_:)`, а MainWindow забирает
/// словарь через `.overlayPreferenceValue` и переводит якоря в координаты своего
/// пространства — в системе, где рисуется затемнение.
struct OnboardingAnchorKey: PreferenceKey {
    static let defaultValue: [OnboardingTarget: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [OnboardingTarget: Anchor<CGRect>],
        nextValue: () -> [OnboardingTarget: Anchor<CGRect>]
    ) {
        // При совпадении цели оставляем первый якорь: целей одного вида по одной.
        value.merge(nextValue()) { existing, _ in existing }
    }
}

extension View {
    /// Помечает вью целью подсветки онбординга.
    func onboardingTarget(_ target: OnboardingTarget) -> some View {
        anchorPreference(key: OnboardingAnchorKey.self, value: .bounds) {
            [target: $0]
        }
    }
}

// MARK: - Overlay

/// Полноэкранный слой поверх окна: затемнение фона, вырез с рамкой вокруг цели
/// текущего шага и карточка с текстом рядом. Чисто обучающий — перехватывает все
/// клики, взаимодействовать с подсвеченным элементом нельзя.
struct OnboardingOverlay: View {
    @Bindable var onboarding: OnboardingModel
    /// Координаты целей в пространстве overlay. Пусты для шагов без подсветки
    /// или пока вью-цель ещё не отдала свой якорь.
    let targets: [OnboardingTarget: CGRect]
    let bounds: CGSize

    /// Отступ выреза от границ элемента и радиус его скругления.
    private let cutoutPadding: CGFloat = 6
    private let cutoutRadius: CGFloat = 10

    var body: some View {
        if let step = onboarding.currentStep {
            let hole = cutoutRect(for: step)
            ZStack(alignment: .topLeading) {
                dimming(hole: hole)
                if let hole {
                    // Accent-рамка со свечением по контуру выреза.
                    RoundedRectangle(cornerRadius: cutoutRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: hole.width, height: hole.height)
                        .offset(x: hole.minX, y: hole.minY)
                        .shadow(color: Color.accentColor.opacity(0.6), radius: 8)
                        .allowsHitTesting(false)
                }
                card(step: step, hole: hole)
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .transition(.opacity)
            // Стрелки листают тур; Esc закрывает. Фокус нужен, чтобы клавиши
            // ловились сразу после появления overlay.
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { onboarding.back(); return .handled }
            .onKeyPress(.rightArrow) { onboarding.next(); return .handled }
            .onKeyPress(.escape) { onboarding.skip(); return .handled }
        }
    }

    // MARK: Затемнение

    /// Тёмный слой с «дырой» вокруг цели. Клик по нему закрывает тур.
    private func dimming(hole: CGRect?) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.5))
            .overlay {
                if let hole {
                    // Вырез: прямоугольник цели вычитается из затемнения.
                    RoundedRectangle(cornerRadius: cutoutRadius)
                        .frame(width: hole.width, height: hole.height)
                        .offset(x: hole.minX, y: hole.minY)
                        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .contentShape(Rectangle())
            .onTapGesture { onboarding.skip() }
    }

    /// Прямоугольник выреза для шага, или nil, если подсвечивать нечего
    /// (шаги без цели, а также цель в тулбаре, недостижимая для overlay).
    private func cutoutRect(for step: OnboardingStep) -> CGRect? {
        guard step.target != .none, step.target != .versionChip,
              let rect = targets[step.target] else { return nil }
        return rect.insetBy(dx: -cutoutPadding, dy: -cutoutPadding)
    }

    // MARK: Карточка

    private func card(step: OnboardingStep, hole: CGRect?) -> some View {
        let placement = cardPlacement(for: step, hole: hole)
        return OnboardingCard(step: step, onboarding: onboarding)
            .frame(width: OnboardingCard.width)
            .position(placement)
    }

    /// Центр карточки. Рядом с вырезом, если он есть; для чипа версии — правый
    /// верхний угол под тулбаром; иначе центр окна.
    private func cardPlacement(for step: OnboardingStep, hole: CGRect?) -> CGPoint {
        let half = OnboardingCard.width / 2
        let margin: CGFloat = 16
        // Высота карточки заранее неизвестна (зависит от текста); оценка нужна
        // лишь чтобы не выйти за край — position центрирует по факту.
        let estimatedHalfHeight: CGFloat = 90

        switch step.target {
        case .versionChip:
            // Правый верхний угол: чип живёт там, в тулбаре.
            return CGPoint(x: bounds.width - half - margin,
                           y: estimatedHalfHeight + margin)
        case .none:
            return CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        default:
            guard let hole else {
                return CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            }
            // По умолчанию — под вырезом; если снизу тесно, ставим над ним.
            let below = hole.maxY + margin + estimatedHalfHeight
            let y = below + estimatedHalfHeight < bounds.height
                ? hole.maxY + margin + estimatedHalfHeight
                : hole.minY - margin - estimatedHalfHeight
            // По горизонтали держим карточку у левого края цели, не вылезая за окно.
            let x = min(max(hole.minX + half, half + margin),
                        bounds.width - half - margin)
            return CGPoint(x: x, y: max(y, estimatedHalfHeight + margin))
        }
    }
}

// MARK: - Карточка шага

/// Белая карточка с заголовком «N из 6», текстом шага и кнопками навигации.
struct OnboardingCard: View {
    let step: OnboardingStep
    @Bindable var onboarding: OnboardingModel

    static let width: CGFloat = 320

    private var stepNumber: Int { step.rawValue + 1 }
    private var totalSteps: Int { OnboardingStep.allCases.count }
    private var isFirst: Bool { step.rawValue == 0 }
    private var isLast: Bool { step.rawValue == totalSteps - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(stepNumber) ИЗ \(totalSteps)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentColor)

            Text(step.title)
                .font(.system(size: 16, weight: .bold))

            Text(step.body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            controls
                .padding(.top, 4)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.background)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        )
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if !isLast {
                Button("Пропустить") { onboarding.skip() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // Точки-индикаторы прогресса.
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { index in
                    Circle()
                        .fill(index == step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer(minLength: 0)

            if !isFirst {
                Button("Назад") { onboarding.back() }
            }
            Button(isLast ? "Готово" : "Далее") { onboarding.next() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}
