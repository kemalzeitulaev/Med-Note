import Foundation
import SwiftUI
import CryptoKit

enum SubscriptionTier: String, Codable, CaseIterable {
    case free, trial, premium
    /// Полный доступ, выданный промокодом.
    case promo

    var title: String {
        switch self {
        case .free: "Бесплатный"
        case .trial: "Пробный период"
        case .premium: "Premium"
        case .promo: "Промо-доступ"
        }
    }

    var showsAds: Bool { self == .free }
}

/// Язык интерфейса и ответов ассистента. Многоязычность — ключевая фишка продукта.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case ru, en, kk, tr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ru: "Русский"
        case .en: "English"
        case .kk: "Қазақша"
        case .tr: "Türkçe"
        }
    }

    var flag: String {
        switch self {
        case .ru: "🇷🇺"
        case .en: "🇬🇧"
        case .kk: "🇰🇿"
        case .tr: "🇹🇷"
        }
    }

    /// Название языка для system-промпта ИИ.
    var promptName: String {
        switch self {
        case .ru: "русском"
        case .en: "английском"
        case .kk: "казахском"
        case .tr: "турецком"
        }
    }
}

/// Настройки приложения. Хранятся в UserDefaults, ключ API — отдельно.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var userName: String {
        didSet { defaults.set(userName, forKey: Keys.userName) }
    }
    var university: String {
        didSet { defaults.set(university, forKey: Keys.university) }
    }
    var course: Int {
        didSet { defaults.set(course, forKey: Keys.course) }
    }
    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    var tier: SubscriptionTier {
        didSet { defaults.set(tier.rawValue, forKey: Keys.tier) }
    }
    var trialStartedAt: Date? {
        didSet { defaults.set(trialStartedAt, forKey: Keys.trialStarted) }
    }
    var hasSeenOnboarding: Bool {
        didSet { defaults.set(hasSeenOnboarding, forKey: Keys.onboarding) }
    }
    var termHintsEnabled: Bool {
        didSet { defaults.set(termHintsEnabled, forKey: Keys.termHints) }
    }
    var dailyGoalMinutes: Int {
        didSet { defaults.set(dailyGoalMinutes, forKey: Keys.dailyGoal) }
    }
    /// Напоминать ли о занятиях и дедлайнах.
    var remindersEnabled: Bool {
        didSet { defaults.set(remindersEnabled, forKey: Keys.reminders) }
    }
    /// За сколько минут до начала приходит напоминание.
    var reminderLeadMinutes: Int {
        didSet { defaults.set(reminderLeadMinutes, forKey: Keys.reminderLead) }
    }

    // Конфигурация ИИ-провайдера
    /// Ключ провайдера. Значение живёт в Keychain, здесь — только копия в памяти,
    /// чтобы поле можно было связать с `SecureField`.
    var apiKey: String {
        didSet {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            // Пробелы по краям — частая беда при вставке ключа из буфера;
            // подрезаем один раз здесь, чтобы проверка «ключ задан» и заголовок
            // запроса всегда видели одно и то же значение.
            if trimmed != apiKey {
                apiKey = trimmed
                return
            }
            Keychain.set(trimmed, for: .aiAPIKey)
        }
    }
    var apiBaseURL: String {
        didSet { defaults.set(apiBaseURL, forKey: Keys.apiBase) }
    }
    var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }

    // Промокоды
    /// Активированный код в каноническом виде.
    private(set) var activePromoCode: String? {
        didSet { defaults.set(activePromoCode, forKey: Keys.activePromo) }
    }
    /// Когда истекает промо-доступ. `nil` при бессрочном коде.
    private(set) var promoExpiresAt: Date? {
        didSet { defaults.set(promoExpiresAt, forKey: Keys.promoExpires) }
    }
    /// Коды, уже активированные на этом устройстве.
    private(set) var redeemedPromoCodes: [String] {
        didSet { defaults.set(redeemedPromoCodes, forKey: Keys.redeemedPromos) }
    }

    /// Загружены ли учебные примеры. При первом запуске база пуста —
    /// пользователь сам решает, нужна ли ему демонстрация.
    var hasSeededSamples: Bool {
        didSet { defaults.set(hasSeededSamples, forKey: Keys.seeded) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let userName = "userName"
        static let university = "university"
        static let course = "course"
        static let language = "language"
        static let tier = "tier"
        static let trialStarted = "trialStartedAt"
        static let onboarding = "hasSeenOnboarding"
        static let termHints = "termHintsEnabled"
        static let dailyGoal = "dailyGoalMinutes"
        static let reminders = "remindersEnabled"
        static let reminderLead = "reminderLeadMinutes"
        static let apiKey = "apiKey"
        static let apiBase = "apiBaseURL"
        static let model = "model"
        static let activePromo = "activePromoCode"
        static let promoExpires = "promoExpiresAt"
        static let redeemedPromos = "redeemedPromoCodes"
        static let seeded = "hasSeededSamples"
    }

    private init() {
        userName = defaults.string(forKey: Keys.userName) ?? ""
        university = defaults.string(forKey: Keys.university) ?? ""
        course = defaults.object(forKey: Keys.course) as? Int ?? 1
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "ru") ?? .ru
        tier = SubscriptionTier(rawValue: defaults.string(forKey: Keys.tier) ?? "free") ?? .free
        trialStartedAt = defaults.object(forKey: Keys.trialStarted) as? Date
        hasSeenOnboarding = defaults.bool(forKey: Keys.onboarding)
        termHintsEnabled = defaults.object(forKey: Keys.termHints) as? Bool ?? true
        dailyGoalMinutes = defaults.object(forKey: Keys.dailyGoal) as? Int ?? 60
        remindersEnabled = defaults.object(forKey: Keys.reminders) as? Bool ?? true
        reminderLeadMinutes = defaults.object(forKey: Keys.reminderLead) as? Int ?? 30
        apiKey = Keychain.string(.aiAPIKey) ?? ""
        apiBaseURL = defaults.string(forKey: Keys.apiBase) ?? "https://api.openai.com/v1"
        model = defaults.string(forKey: Keys.model) ?? "gpt-4o-mini"
        activePromoCode = defaults.string(forKey: Keys.activePromo)
        promoExpiresAt = defaults.object(forKey: Keys.promoExpires) as? Date
        redeemedPromoCodes = defaults.stringArray(forKey: Keys.redeemedPromos) ?? []
        hasSeededSamples = defaults.bool(forKey: Keys.seeded)

        migrateAPIKeyToKeychain()
        refreshAccessState()
    }

    /// Ранние сборки держали ключ в UserDefaults. Переносим его в Keychain
    /// и стираем открытую копию.
    private func migrateAPIKeyToKeychain() {
        guard let legacy = defaults.string(forKey: Keys.apiKey) else { return }
        let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty, !trimmed.isEmpty {
            apiKey = trimmed
        }
        defaults.removeObject(forKey: Keys.apiKey)
    }

    // MARK: - Подписка

    static let trialLength = 7

    /// Сколько дней пробного периода осталось. Считаем по реальным суткам
    /// от момента старта, а не по датам в календаре: иначе триал, начатый
    /// в 23:50, терял целый день уже через десять минут.
    var trialDaysLeft: Int {
        guard let start = trialStartedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(start) / 86_400
        return max(0, Int((Double(Self.trialLength) - elapsed).rounded(.up)))
    }

    var isTrialActive: Bool { tier == .trial && trialDaysLeft > 0 }

    var hasFullAccess: Bool {
        switch tier {
        case .premium: true
        case .promo: promoDaysLeft.map { $0 > 0 } ?? true
        case .trial: trialDaysLeft > 0
        case .free: false
        }
    }

    /// Пробный период даётся один раз.
    var canStartTrial: Bool { trialStartedAt == nil && tier == .free }

    func startTrial() {
        guard canStartTrial else { return }
        trialStartedAt = Date()
        tier = .trial
    }

    /// Приводит тариф в соответствие с тем, что говорит App Store.
    /// Единственный источник правды о платной подписке — StoreKit,
    /// поэтому активная покупка включает Premium, а её отсутствие снимает.
    func applyStoreEntitlement(isActive: Bool) {
        if isActive {
            tier = .premium
        } else if tier == .premium {
            // Промо и триал не трогаем: они живут без App Store.
            tier = trialDaysLeft > 0 ? .trial : .free
        }
    }

    /// Снимает истёкшие доступы. Вызывается при запуске и при возврате
    /// в приложение — иначе после недели в фоне пользователь видел бы
    /// «Пробный период» с нулём оставшихся дней.
    func refreshAccessState() {
        if tier == .promo, let promoExpiresAt, Date() > promoExpiresAt {
            self.promoExpiresAt = nil
            activePromoCode = nil
            tier = .free
        }
        if tier == .trial, trialDaysLeft == 0 {
            tier = .free
        }
    }

    // MARK: - Промокоды

    /// Сколько дней промо-доступа осталось. `nil` — доступ бессрочный.
    var promoDaysLeft: Int? {
        guard let promoExpiresAt else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: promoExpiresAt).day ?? 0
        return max(0, days + 1)
    }

    /// Активирует промокод: проверяет подпись, срок и повторное использование.
    @discardableResult
    func redeem(_ raw: String) -> Result<PromoCode, PromoCodeError> {
        let result = PromoCodeService.verify(raw)
        guard case .success(let code) = result else { return result }
        let fingerprint = Self.promoFingerprint(code.normalized)
        guard !redeemedPromoCodes.contains(code.normalized),
              !redeemedPromoCodes.contains(fingerprint) else {
            return .failure(.alreadyUsed)
        }

        switch code.benefit {
        case .unlimited:
            promoExpiresAt = nil
        case .days(let days):
            promoExpiresAt = Calendar.current.date(byAdding: .day, value: days, to: Date())
        }
        activePromoCode = code.normalized
        redeemedPromoCodes.append(fingerprint)
        tier = .promo
        return result
    }

    /// Хеш кода, а не сам код: в UserDefaults не лежит выпущенный промокод.
    private static func promoFingerprint(_ normalized: String) -> String {
        SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Отменяет промо-доступ вручную — например, чтобы активировать другой код.
    func clearPromo() {
        promoExpiresAt = nil
        activePromoCode = nil
        if tier == .promo {
            tier = StoreService.shared.hasActiveSubscription ? .premium : .free
        }
    }

    /// Настроен ли реальный ИИ-провайдер (иначе работает демо-режим).
    var isLiveAIConfigured: Bool { !apiKey.isEmpty }

    /// Базовый адрес без хвостового слэша — иначе в URL появлялся двойной `//`,
    /// и часть провайдеров отвечала на такой запрос ошибкой 404.
    var normalizedBaseURL: String {
        var value = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    var greetingName: String {
        userName.trimmingCharacters(in: .whitespaces).isEmpty ? "коллега" : userName
    }
}
