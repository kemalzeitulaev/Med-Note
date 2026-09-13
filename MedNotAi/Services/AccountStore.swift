import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Зашифрованная локальная база аккаунтов.
///
/// Пароль никогда не пишется на диск: хранятся только уникальная соль
/// и результат PBKDF2-HMAC-SHA256. Сам файл дополнительно закрыт AES-GCM,
/// ключ лежит в Keychain с флагом `ThisDeviceOnly` — его нет в iCloud
/// и в резервных копиях устройства.
actor AccountStore {
    static let shared = AccountStore()

    /// OWASP (2023) для PBKDF2-HMAC-SHA256. Сотни тысяч итераций делают
    /// перебор с украденным файлом дорогим даже на GPU.
    static let pbkdf2Iterations: UInt32 = 600_000
    private static let saltLength = 16
    private static let keyLength = 32
    private static let maxFailedAttempts = 5
    private static let lockDuration: TimeInterval = 15 * 60

    private let fileURL: URL
    private var cache: Vault?

    private init() {
        let directory = AccountStore.storageDirectory()
        fileURL = directory.appendingPathComponent("accounts.vault", isDirectory: false)
    }

    // MARK: - Публичный API

    func register(email: String, displayName: String?, password: String) async throws -> StoredAccount {
        try Self.validatePassword(password, email: email)
        var vault = try load()
        guard vault.account(for: email) == nil else { throw AuthError.accountExists }

        let salt = Self.randomBytes(Self.saltLength)
        let hash = Self.derive(password: password, salt: salt, iterations: Self.pbkdf2Iterations)
        let now = Date()
        let account = StoredAccount(
            id: UUID(),
            email: email,
            displayName: displayName,
            createdAt: now,
            lastSignInAt: now,
            salt: salt,
            passwordHash: hash,
            iterations: Self.pbkdf2Iterations,
            failedAttempts: 0,
            lockedUntil: nil
        )
        vault.accounts.append(account)
        try persist(vault)
        return account
    }

    func authenticate(email: String, password: String, displayName: String? = nil) async throws -> StoredAccount {
        var vault = try load()
        guard var account = vault.account(for: email) else {
            // Считаем хеш и для несуществующего адреса, чтобы время ответа
            // не выдавало, есть ли такая почта в базе.
            _ = Self.dummyVerify(password)
            throw AuthError.wrongPassword
        }

        if let lockedUntil = account.lockedUntil, lockedUntil > Date() {
            throw AuthError.accountLocked(until: lockedUntil)
        }

        let computed = Self.derive(password: password, salt: account.salt, iterations: account.iterations)
        guard Self.timingSafeEqual(computed, account.passwordHash) else {
            account.failedAttempts += 1
            if account.failedAttempts >= Self.maxFailedAttempts {
                account.lockedUntil = Date().addingTimeInterval(Self.lockDuration)
                account.failedAttempts = 0
            }
            vault.upsert(account)
            try persist(vault)
            if let lockedUntil = account.lockedUntil, lockedUntil > Date() {
                throw AuthError.accountLocked(until: lockedUntil)
            }
            throw AuthError.wrongPassword
        }

        if account.iterations < Self.pbkdf2Iterations {
            account.salt = Self.randomBytes(Self.saltLength)
            account.iterations = Self.pbkdf2Iterations
            account.passwordHash = Self.derive(password: password, salt: account.salt, iterations: account.iterations)
        }
        account.failedAttempts = 0
        account.lockedUntil = nil
        account.lastSignInAt = Date()
        if let displayName, account.displayName == nil {
            account.displayName = displayName
        }
        vault.upsert(account)
        try persist(vault)
        return account
    }

    func updateDisplayName(_ name: String?, for email: String) async {
        guard var vault = try? load(), var account = vault.account(for: email) else { return }
        account.displayName = name
        vault.upsert(account)
        try? persist(vault)
    }

    func deleteAccount(email: String) async {
        guard var vault = try? load() else { return }
        vault.accounts.removeAll { $0.email == email }
        try? persist(vault)
    }

    func hasAccount(email: String) async -> Bool {
        (try? load().account(for: email)) != nil
    }

    /// Кладёт аккаунт, пришедший из iCloud, в локальный сейф — без повторного хеширования пароля.
    func cacheRemote(_ account: StoredAccount) async {
        guard var vault = try? load() else { return }
        if vault.account(for: account.email) == nil {
            vault.accounts.append(account)
            try? persist(vault)
        }
    }

    /// Переносит старую одноаккаунтную запись из Keychain в хранилище.
    func importLegacyIfNeeded(_ legacy: EmailCredentials, password: String) async throws -> StoredAccount {
        if let existing = try load().account(for: legacy.email) {
            return try await authenticate(email: existing.email, password: password)
        }
        guard legacy.matches(password: password) else { throw AuthError.wrongPassword }
        return try await register(email: legacy.email, displayName: nil, password: password)
    }

    // MARK: - Файл

    private func load() throws -> Vault {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = Vault()
            cache = empty
            return empty
        }
        let blob = try Data(contentsOf: fileURL)
        let vault = try Self.decrypt(blob, key: try Self.vaultKey())
        cache = vault
        return vault
    }

    private func persist(_ vault: Vault) throws {
        let blob = try Self.encrypt(vault, key: try Self.vaultKey())
        let temporary = fileURL.appendingPathExtension("tmp")
        try blob.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        cache = vault
    }

    private static func storageDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("MedNotAi", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Шифрование хранилища

    private static func vaultKey() throws -> SymmetricKey {
        if let existing = Keychain.data(.accountsVaultKey), existing.count == keyLength {
            return SymmetricKey(data: existing)
        }
        let raw = randomBytes(keyLength)
        guard Keychain.set(raw, for: .accountsVaultKey) else {
            throw AuthError.storeUnavailable
        }
        return SymmetricKey(data: raw)
    }

    private static func encrypt(_ vault: Vault, key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(vault)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw AuthError.storeUnavailable }
        return combined
    }

    private static func decrypt(_ blob: Data, key: SymmetricKey) throws -> Vault {
        let box = try AES.GCM.SealedBox(combined: blob)
        let plaintext = try AES.GCM.open(box, using: key)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Vault.self, from: plaintext)
    }

    // MARK: - Пароль

    nonisolated static func validatePassword(_ password: String, email: String) throws {
        guard password.count >= 8 else { throw AuthError.weakPassword }
        guard password.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw AuthError.weakPassword
        }
        guard password.lowercased() != email.lowercased() else { throw AuthError.weakPassword }
        let hasLetter = password.rangeOfCharacter(from: .letters) != nil
        let hasDigit = password.rangeOfCharacter(from: .decimalDigits) != nil
        guard hasLetter, hasDigit else { throw AuthError.weakPassword }
    }

    nonisolated static func derive(password: String, salt: Data, iterations: UInt32) -> Data {
        var derived = Data(count: keyLength)
        let status: Int32 = password.withCString { passwordPtr in
            salt.withUnsafeBytes { saltRaw in
                derived.withUnsafeMutableBytes { derivedRaw in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr,
                        strlen(passwordPtr),
                        saltRaw.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedRaw.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        if status != kCCSuccess {
            return Data(count: keyLength)
        }
        return derived
    }

    /// Сравнение без раннего выхода: иначе по времени ответа можно понять,
    /// на каком байте хеши разошлись.
    nonisolated static func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    nonisolated private static func dummyVerify(_ password: String) -> Data {
        derive(password: password, salt: Data(repeating: 0xA5, count: saltLength), iterations: pbkdf2Iterations)
    }

    nonisolated static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            bytes = (0..<count).map { _ in UInt8.random(in: 0...UInt8.max) }
        }
        return Data(bytes)
    }
}

// MARK: - Модели хранилища

struct StoredAccount: Codable, Equatable, Sendable {
    var id: UUID
    var email: String
    var displayName: String?
    var createdAt: Date
    var lastSignInAt: Date?
    var salt: Data
    var passwordHash: Data
    var iterations: UInt32
    var failedAttempts: Int
    var lockedUntil: Date?
}

private struct Vault: Codable, Sendable {
    var version: Int = 1
    var accounts: [StoredAccount] = []

    func account(for email: String) -> StoredAccount? {
        accounts.first { $0.email == email }
    }

    mutating func upsert(_ account: StoredAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }
}
