import Foundation
import Security

/// Хранилище секретов: ключ ИИ-провайдера, идентификатор входа, токены OAuth.
///
/// UserDefaults для этого не подходит: его plist лежит в контейнере приложения
/// открытым текстом, попадает в резервные копии iTunes/Finder и читается любым
/// процессом, получившим доступ к файлам. Keychain шифруется системой и здесь
/// дополнительно ограничен `ThisDeviceOnly` — секреты не уезжают в iCloud
/// и не переносятся на новое устройство вместе с бэкапом.
enum Keychain {

    enum Item: String {
        /// Ключ OpenAI-совместимого провайдера.
        case aiAPIKey = "ai.api-key"
        /// Стабильный идентификатор пользователя от Sign in with Apple.
        case appleUserID = "auth.apple.user-id"
        /// Сериализованный профиль вошедшего пользователя.
        case authProfile = "auth.profile"
        /// Refresh-токен Google: обновляет доступ без повторного входа.
        case googleRefreshToken = "auth.google.refresh-token"
        /// Устаревшая одноаккаунтная запись. После первого входа переносится в vault.
        case emailCredentials = "auth.email.credentials"
        /// 256-битный ключ AES-GCM для файла аккаунтов. Сами пароли здесь не лежат.
        case accountsVaultKey = "auth.accounts.vault-key"
    }

    private static let service = Bundle.main.bundleIdentifier ?? "kemal.MedNotAi"

    // MARK: - Строки

    nonisolated static func string(_ item: Item) -> String? {
        data(item).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    nonisolated static func set(_ value: String?, for item: Item) -> Bool {
        guard let value, !value.isEmpty else { return remove(item) }
        return set(Data(value.utf8), for: item)
    }

    // MARK: - Данные

    nonisolated static func data(_ item: Item) -> Data? {
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    nonisolated static func set(_ value: Data, for item: Item) -> Bool {
        let query = baseQuery(item)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    nonisolated static func remove(_ item: Item) -> Bool {
        let status = SecItemDelete(baseQuery(item) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Стирает все секреты — при выходе из аккаунта.
    nonisolated static func removeAll() {
        for item in [Item.aiAPIKey, .appleUserID, .authProfile, .googleRefreshToken, .emailCredentials] {
            remove(item)
        }
    }

    // MARK: - Codable

    nonisolated static func decode<T: Decodable>(_ type: T.Type, from item: Item) -> T? {
        data(item).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    @discardableResult
    nonisolated static func encode<T: Encodable>(_ value: T, to item: Item) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return set(data, for: item)
    }

    // MARK: - Внутреннее

    private nonisolated static func baseQuery(_ item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            // Без синхронизации: секрет остаётся на этом устройстве.
            kSecAttrSynchronizable as String: false
        ]
    }
}
