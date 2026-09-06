import Foundation

extension AppLanguage {
    var localeIdentifier: String {
        switch self {
        case .ru: "ru_RU"
        case .en: "en_US"
        case .kk: "kk_KZ"
        case .tr: "tr_TR"
        }
    }
}

/// Локаль форматирования дат и чисел. Следует за языком, выбранным в настройках,
/// а не за языком системы — иначе интерфейс на русском показывал бы «3 hours ago».
enum AppLocale {
    static var current: Locale {
        Locale(identifier: AppSettings.shared.language.localeIdentifier)
    }
}

extension Date {
    /// Форматирование с учётом выбранного в приложении языка.
    func localized(_ style: Date.FormatStyle) -> String {
        formatted(style.locale(AppLocale.current))
    }

    var localizedTime: String {
        localized(Date.FormatStyle(date: .omitted, time: .shortened))
    }

    var localizedRelative: String {
        formatted(Date.RelativeFormatStyle(presentation: .named).locale(AppLocale.current))
    }
}

extension String {
    /// Убирает markdown-разметку — нужно для превью в списках.
    var plainText: String {
        var text = self
        for marker in ["**", "__", "`", "###", "##", "#"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "• ", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    /// Ключ для сравнения текстов без учёта регистра и лишних пробелов.
    var normalizedForCompare: String {
        lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Русские формы множественного числа: 1 конспект, 2 конспекта, 5 конспектов.
func pluralRu(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    let mod100 = abs(count) % 100
    let mod10 = abs(count) % 10
    let word: String
    if mod100 >= 11 && mod100 <= 14 {
        word = many
    } else if mod10 == 1 {
        word = one
    } else if mod10 >= 2 && mod10 <= 4 {
        word = few
    } else {
        word = many
    }
    return "\(count) \(word)"
}
