import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Метрики адаптивной раскладки. Приложение работает на iPhone, iPad и Mac,
/// поэтому контент не должен растягиваться на всю ширину большого окна.
enum Layout {
    /// Предельная ширина колонки с текстом и карточками.
    static let contentMaxWidth: CGFloat = 760
    /// Предельная ширина узкой колонки (список в сплит-вью).
    static let listMinWidth: CGFloat = 300
    static let listIdealWidth: CGFloat = 360
    static let listMaxWidth: CGFloat = 440
    /// Минимальный размер окна на Mac.
    static let windowMinWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 620
    /// Размеры модальных окон на Mac (на iOS шиты растягиваются сами).
    static let sheetWidth: CGFloat = 560
    static let sheetHeight: CGFloat = 620

    /// Ширина, с которой раскладка считается широкой.
    static let wideBreakpoint: CGFloat = 700
}

private struct WideLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Широкая раскладка: iPad и окно на Mac. Проставляется в корне приложения.
    var isWideLayout: Bool {
        get { self[WideLayoutKey.self] }
        set { self[WideLayoutKey.self] = newValue }
    }
}

extension View {
    /// Ограничивает ширину контента и центрирует его — иначе на 13" iPad
    /// строки текста становятся неудобно длинными.
    func readableWidth(_ maxWidth: CGFloat = Layout.contentMaxWidth) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }

    /// Задаёт размер модального окна на Mac, где шиты не растягиваются.
    func macSheetSize(width: CGFloat = Layout.sheetWidth, height: CGFloat = Layout.sheetHeight) -> some View {
        #if os(macOS)
        return frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        return self
        #endif
    }

    /// Ширина боковой колонки в сплит-вью.
    func listColumnWidth() -> some View {
        navigationSplitViewColumnWidth(
            min: Layout.listMinWidth,
            ideal: Layout.listIdealWidth,
            max: Layout.listMaxWidth
        )
    }

    /// Измеряет ширину, не ломая раскладку: GeometryReader стоит фоном,
    /// а не родителем. Иначе TabView в симуляторе получает нулевую высоту.
    func measuredWidth() -> some View {
        modifier(MeasuredWidthModifier())
    }
}

private struct LayoutWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MeasuredWidthModifier: ViewModifier {
    @State private var isWide = false

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: LayoutWidthKey.self, value: geo.size.width)
                }
            }
            .onPreferenceChange(LayoutWidthKey.self) { width in
                isWide = width >= Layout.wideBreakpoint
            }
            .environment(\.isWideLayout, isWide)
    }
}

/// Кросс-платформенный буфер обмена: на Mac UIPasteboard недоступен.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
