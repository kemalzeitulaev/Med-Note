import SwiftUI

// MARK: - Карточка

struct GlassCard<Content: View>: View {
    var padding: CGFloat = Theme.cardPadding
    /// Подсветка выбранного элемента в сплит-вью на iPad и Mac.
    var isHighlighted: Bool = false
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(isHighlighted ? Theme.surfaceTint : Theme.cardFill(scheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(isHighlighted ? Theme.primary.opacity(0.65) : Theme.hairline.opacity(scheme == .dark ? 0.25 : 0.9),
                            lineWidth: isHighlighted ? 1.5 : 1)
            }
            .shadow(color: Theme.primary.opacity(scheme == .dark ? 0 : 0.07), radius: 14, y: 6)
    }
}

// MARK: - Кнопки

struct BrandButtonStyle: ButtonStyle {
    var expands: Bool = true

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 15)
            .padding(.horizontal, 22)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(Theme.brandGradient, in: Capsule())
            .shadow(color: Theme.primary.opacity(isEnabled ? 0.35 : 0), radius: 12, y: 6)
            .opacity(isEnabled ? 1 : 0.4)
            .saturation(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var expands: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.primaryDeep)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(Theme.chipGradient, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

// MARK: - Иконка в «пилюле»

struct GradientIcon: View {
    let systemName: String
    var size: CGFloat = 44
    var colors: [Color] = [Color(hex: 0xA855F7), Color(hex: 0xEC4899)]

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            )
            .shadow(color: colors.first?.opacity(0.35) ?? .clear, radius: 8, y: 4)
    }
}

// MARK: - Заголовок раздела

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
            }
        }
    }
}

// MARK: - Чип / тег

struct TagChip: View {
    let text: String
    var color: Color = Theme.primary
    var icon: String?

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.caption2.weight(.bold)) }
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(color.opacity(0.13), in: Capsule())
    }
}

// MARK: - Пустое состояние

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            GradientIcon(systemName: icon, size: 66)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(BrandButtonStyle(expands: false))
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Индикатор «ИИ печатает»

struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.primary)
                    .frame(width: 7, height: 7)
                    .opacity(0.35 + 0.65 * abs(sin(phase + Double(i) * 0.7)))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

// MARK: - Прогресс-полоса

struct BrandProgressBar: View {
    let value: Double  // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceTint)
                Capsule()
                    .fill(Theme.brandGradient)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 8)
    }
}
