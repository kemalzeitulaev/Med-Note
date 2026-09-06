import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Палитра и токены оформления MedNoteAi.
/// Основана на фирменной фиолетово-розовой гамме из презентации.
/// Цвета адаптивные: приложение работает и в светлой, и в тёмной теме на iPhone, iPad и Mac.
enum Theme {

    // MARK: - Цвета

    static let primary = Color.adaptive(light: 0x9333EA, dark: 0xC084FC)
    static let primaryDeep = Color.adaptive(light: 0x6D28D9, dark: 0xD8B4FE)
    static let primarySoft = Color.adaptive(light: 0xC084FC, dark: 0x9333EA)
    static let accentPink = Color.adaptive(light: 0xEC4899, dark: 0xF9A8D4)
    static let accentCyan = Color.adaptive(light: 0x0284C7, dark: 0x7DD3FC)

    static let surfaceTint = Color.adaptive(light: 0xF3E8FF, dark: 0x2A2140)
    static let hairline = Color.adaptive(light: 0xE9D5FF, dark: 0x6D5A9C)

    static let textPrimary = Color.adaptive(light: 0x1B1236, dark: 0xF2EDFA)
    static let textSecondary = Color.adaptive(light: 0x6B6382, dark: 0xA9A2BF)

    static let success = Color.adaptive(light: 0x059669, dark: 0x34D399)
    static let warning = Color.adaptive(light: 0xD97706, dark: 0xFBBF24)
    static let danger = Color.adaptive(light: 0xDC2626, dark: 0xF87171)

    /// Заливка карточек и полей ввода.
    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.92)
    }

    // MARK: - Градиенты

    static let brandGradient = LinearGradient(
        colors: [Color(hex: 0x7C3AED), Color(hex: 0xA855F7), Color(hex: 0xEC4899)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let chipGradient = LinearGradient(
        colors: [Color(hex: 0xA855F7).opacity(0.16), Color(hex: 0xEC4899).opacity(0.14)],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: - Метрики

    static let cornerRadius: CGFloat = 20
    static let cardPadding: CGFloat = 16

    /// Палитра для цветовой маркировки конспектов и предметов.
    static let paletteColors: [Color] = [
        Color(hex: 0x9333EA), Color(hex: 0xEC4899), Color(hex: 0x0EA5E9),
        Color(hex: 0x10B981), Color(hex: 0xF59E0B), Color(hex: 0xEF4444),
        Color(hex: 0x6366F1), Color(hex: 0x14B8A6)
    ]

    static func paletteColor(_ index: Int) -> Color {
        paletteColors[abs(index) % paletteColors.count]
    }
}

/// Фон приложения: мягкое сияние в углах на почти белой (или почти чёрной) основе.
/// Отдельное вью, а не функция, чтобы самому читать тему из окружения.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            (scheme == .dark ? Color(hex: 0x120B1F) : Color(hex: 0xFBF9FF))
            RadialGradient(
                colors: [Color(hex: 0xA855F7).opacity(scheme == .dark ? 0.28 : 0.20), .clear],
                center: .topLeading, startRadius: 8, endRadius: 560
            )
            RadialGradient(
                colors: [Color(hex: 0xEC4899).opacity(scheme == .dark ? 0.20 : 0.14), .clear],
                center: .bottomTrailing, startRadius: 8, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Цвета из hex с поддержкой тёмной темы

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// Цвет, который сам подстраивается под светлую и тёмную тему.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #elseif canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        return Color(hex: light)
        #endif
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#elseif canImport(UIKit)
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
