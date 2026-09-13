import Foundation
import CloudKit
import CryptoKit

/// Общая база аккаунтов в iCloud (CloudKit).
///
/// В облако уходит только почта, соль и PBKDF2-хеш — сам пароль никогда.
/// Запись лежит в публичной базе контейнера, поэтому с iPad можно войти
/// в аккаунт, созданный на iPhone. Нужен вход в iCloud на обоих устройствах.
enum AccountCloud {
    static let containerID = "iCloud.kemal.MedNotAi"
    static let recordType = "UserAccount"

    private static var container: CKContainer { CKContainer(identifier: containerID) }
    private static var database: CKDatabase { container.publicCloudDatabase }

    /// Ищем аккаунт по почте. `nil` — записи нет. Ошибки iCloud пробрасываем.
    static func fetch(email: String) async throws -> StoredAccount? {
        try await ensureICloud()
        do {
            let record = try await database.record(for: recordID(for: email))
            return StoredAccount(cloudRecord: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw map(error)
        }
    }

    /// Создаёт или обновляет облачную запись. Пароль в запись не попадает.
    static func publish(_ account: StoredAccount) async throws {
        try await ensureICloud()
        let id = recordID(for: account.email)
        let record: CKRecord
        do {
            record = try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: id)
        } catch {
            throw map(error)
        }
        account.write(to: record)
        do {
            _ = try await database.save(record)
        } catch {
            throw map(error)
        }
    }

    static func delete(email: String) async {
        guard (try? await container.accountStatus()) == .available else { return }
        try? await database.deleteRecord(withID: recordID(for: email))
    }

    // MARK: - Внутреннее

    private static func recordID(for email: String) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "acct_\(digest)")
    }

    private static func ensureICloud() async throws {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw AuthError.cloudUnreachable
        }
        switch status {
        case .available:
            return
        case .noAccount, .restricted, .temporarilyUnavailable:
            throw AuthError.iCloudUnavailable
        case .couldNotDetermine:
            throw AuthError.cloudUnreachable
        @unknown default:
            throw AuthError.iCloudUnavailable
        }
    }

    private static func map(_ error: Error) -> AuthError {
        if let auth = error as? AuthError { return auth }
        if let cloud = error as? CKError {
            switch cloud.code {
            case .notAuthenticated, .managedAccountRestricted:
                return .iCloudUnavailable
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy, .requestRateLimited:
                return .cloudUnreachable
            default:
                return .cloudUnreachable
            }
        }
        return .cloudUnreachable
    }
}

extension StoredAccount {
    fileprivate init?(cloudRecord record: CKRecord) {
        guard let email = record["email"] as? String,
              let salt = record["salt"] as? Data,
              let passwordHash = record["passwordHash"] as? Data else { return nil }
        let iterations = (record["iterations"] as? NSNumber)?.uint32Value ?? AccountStore.pbkdf2Iterations
        let rawID = record["accountID"] as? String
        self.init(
            id: rawID.flatMap(UUID.init(uuidString:)) ?? UUID(),
            email: email,
            displayName: record["displayName"] as? String,
            createdAt: record["createdAt"] as? Date ?? Date(),
            lastSignInAt: nil,
            salt: salt,
            passwordHash: passwordHash,
            iterations: iterations,
            failedAttempts: 0,
            lockedUntil: nil
        )
    }

    fileprivate func write(to record: CKRecord) {
        record["email"] = email as CKRecordValue
        record["salt"] = salt as CKRecordValue
        record["passwordHash"] = passwordHash as CKRecordValue
        record["iterations"] = NSNumber(value: iterations)
        record["accountID"] = id.uuidString as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        if let displayName, !displayName.isEmpty {
            record["displayName"] = displayName as CKRecordValue
        }
    }
}
