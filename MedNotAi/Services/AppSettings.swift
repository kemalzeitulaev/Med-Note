import Foundation
import SwiftUI

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
    var hasSeenOnboarding: Bool {
        didSet { defaults.set(hasSeenOnboarding, forKey: Keys.onboarding) }
    }
    /// Пользователь открыл приложение без входа. Сессии нет, но экран логина
    /// больше не блокирует запуск — войти можно позже из профиля.
    var hasSkippedSignIn: Bool {
        didSet { defaults.set(hasSkippedSignIn, forKey: Keys.skippedSignIn) }
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
        static let onboarding = "hasSeenOnboarding"
        static let skippedSignIn = "hasSkippedSignIn"
        static let termHints = "termHintsEnabled"
        static let dailyGoal = "dailyGoalMinutes"
        static let reminders = "remindersEnabled"
        static let reminderLead = "reminderLeadMinutes"
        static let apiKey = "apiKey"
        static let apiBase = "apiBaseURL"
        static let model = "model"
        static let seeded = "hasSeededSamples"
    }

    private init() {
        userName = defaults.string(forKey: Keys.userName) ?? ""
        university = defaults.string(forKey: Keys.university) ?? ""
        course = defaults.object(forKey: Keys.course) as? Int ?? 1
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "ru") ?? .ru
        hasSeenOnboarding = defaults.bool(forKey: Keys.onboarding)
        hasSkippedSignIn = defaults.bool(forKey: Keys.skippedSignIn)
        termHintsEnabled = defaults.object(forKey: Keys.termHints) as? Bool ?? true
        dailyGoalMinutes = defaults.object(forKey: Keys.dailyGoal) as? Int ?? 60
        remindersEnabled = defaults.object(forKey: Keys.reminders) as? Bool ?? true
        reminderLeadMinutes = defaults.object(forKey: Keys.reminderLead) as? Int ?? 30
        apiKey = Keychain.string(.aiAPIKey) ?? ""
        apiBaseURL = defaults.string(forKey: Keys.apiBase) ?? "https://api.openai.com/v1"
        model = defaults.string(forKey: Keys.model) ?? "gpt-4o-mini"
        hasSeededSamples = defaults.bool(forKey: Keys.seeded)

        migrateAPIKeyToKeychain()
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
