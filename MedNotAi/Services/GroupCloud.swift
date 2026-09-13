import Foundation
import CloudKit
import SwiftData

/// Общие группы и конспекты в публичной базе iCloud.
///
/// Один Apple ID на iPhone и iPad закрывает SwiftData. Разные люди входят
/// по коду: запись группы лежит в CloudKit, а не только на устройстве автора.
enum GroupCloud {
    static let containerID = AccountCloud.containerID
    static let groupType = "SharedStudyGroup"
    static let noteType = "SharedGroupNote"

    private static var container: CKContainer { CKContainer(identifier: containerID) }
    private static var database: CKDatabase { container.publicCloudDatabase }

    // MARK: - Группа

    static func publish(_ group: StudyGroup) async {
        guard (try? await ensureICloud()) != nil else { return }
        let id = groupRecordID(group.inviteCode)
        let record: CKRecord
        do {
            record = try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: groupType, recordID: id)
        } catch {
            return
        }
        record["groupUUID"] = group.id.uuidString as CKRecordValue
        record["name"] = group.name as CKRecordValue
        record["subject"] = group.subject as CKRecordValue
        record["inviteCode"] = group.inviteCode as CKRecordValue
        record["memberNames"] = group.memberNames.joined(separator: "\n") as CKRecordValue
        record["colorIndex"] = NSNumber(value: group.colorIndex)
        record["createdAt"] = group.createdAt as CKRecordValue
        _ = try? await database.save(record)
    }

    static func fetch(code: String) async throws -> CloudGroup {
        try await ensureICloud()
        do {
            let record = try await database.record(for: groupRecordID(code))
            guard let payload = CloudGroup(record: record) else { throw GroupCloudError.notFound }
            return payload
        } catch let error as CKError where error.code == .unknownItem {
            throw GroupCloudError.notFound
        } catch let error as GroupCloudError {
            throw error
        } catch {
            throw map(error)
        }
    }

    // MARK: - Конспект группы

    static func publishNote(_ note: Note) async {
        guard let groupID = note.groupID else { return }
        guard (try? await ensureICloud()) != nil else { return }
        let id = noteRecordID(note.id)
        let record: CKRecord
        do {
            record = try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: noteType, recordID: id)
        } catch {
            return
        }
        record["noteUUID"] = note.id.uuidString as CKRecordValue
        record["groupUUID"] = groupID.uuidString as CKRecordValue
        record["title"] = note.title as CKRecordValue
        record["body"] = clipped(note.body, limit: 90_000) as CKRecordValue
        record["subject"] = note.subject as CKRecordValue
        record["summary"] = clipped(note.summary, limit: 8_000) as CKRecordValue
        record["sourceFileName"] = note.sourceFileName as CKRecordValue
        record["colorIndex"] = NSNumber(value: note.colorIndex)
        record["updatedAt"] = note.updatedAt as CKRecordValue
        _ = try? await database.save(record)
    }

    static func fetchNotes(groupID: UUID) async throws -> [CloudNote] {
        try await ensureICloud()
        let predicate = NSPredicate(format: "groupUUID == %@", groupID.uuidString)
        let query = CKQuery(recordType: noteType, predicate: predicate)
        do {
            let matches = try await database.records(matching: query)
            return matches.matchResults.compactMap { _, result in
                (try? result.get()).flatMap(CloudNote.init(record:))
            }
        } catch {
            throw map(error)
        }
    }

    // MARK: - Склейка с локальной базой

    @discardableResult
    static func join(code: String, myName: String, context: ModelContext) async throws -> StudyGroup {
        let remote = try await fetch(code: code)
        let local = upsert(remote, context: context)
        if !local.memberNames.contains(where: { $0.caseInsensitiveCompare(myName) == .orderedSame }) {
            local.memberNames.append(myName)
            try? context.save()
            await publish(local)
        }
        await pullNotes(into: context, groupID: local.id)
        return local
    }

    static func pull(into context: ModelContext, group: StudyGroup) async {
        if let remote = try? await fetch(code: group.inviteCode) {
            merge(remote, into: group)
            try? context.save()
        }
        await pullNotes(into: context, groupID: group.id)
    }

    static func pullNotes(into context: ModelContext, groupID: UUID) async {
        guard let remote = try? await fetchNotes(groupID: groupID) else { return }
        let existing = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for item in remote {
            if let note = byID[item.id] {
                if item.updatedAt > note.updatedAt {
                    apply(item, to: note)
                }
            } else {
                let note = Note(title: item.title, body: item.body, subject: item.subject, colorIndex: item.colorIndex, groupID: groupID)
                note.id = item.id
                note.summary = item.summary
                note.sourceFileName = item.sourceFileName
                note.updatedAt = item.updatedAt
                context.insert(note)
                byID[item.id] = note
            }
        }
        try? context.save()
    }

    static func upsert(_ remote: CloudGroup, context: ModelContext) -> StudyGroup {
        let all = (try? context.fetch(FetchDescriptor<StudyGroup>())) ?? []
        if let local = all.first(where: { $0.id == remote.id || $0.inviteCode == remote.inviteCode }) {
            merge(remote, into: local)
            try? context.save()
            return local
        }
        let group = StudyGroup(name: remote.name, subject: remote.subject, memberNames: remote.memberNames, colorIndex: remote.colorIndex)
        group.id = remote.id
        group.inviteCode = remote.inviteCode
        group.createdAt = remote.createdAt
        context.insert(group)
        try? context.save()
        return group
    }

    // MARK: - Внутреннее

    private static func merge(_ remote: CloudGroup, into group: StudyGroup) {
        group.name = remote.name
        group.subject = remote.subject
        group.colorIndex = remote.colorIndex
        var names = group.memberNames
        for name in remote.memberNames where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        group.memberNames = names
    }

    private static func apply(_ remote: CloudNote, to note: Note) {
        note.title = remote.title
        note.body = remote.body
        note.subject = remote.subject
        note.summary = remote.summary
        note.sourceFileName = remote.sourceFileName
        note.colorIndex = remote.colorIndex
        note.groupID = remote.groupID
        note.updatedAt = remote.updatedAt
    }

    private static func groupRecordID(_ code: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "grp_\(code.uppercased())")
    }

    private static func noteRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "gnote_\(id.uuidString)")
    }

    @discardableResult
    private static func ensureICloud() async throws -> CKAccountStatus {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw GroupCloudError.unreachable
        }
        switch status {
        case .available:
            return status
        case .noAccount, .restricted, .temporarilyUnavailable:
            throw GroupCloudError.iCloudUnavailable
        default:
            throw GroupCloudError.unreachable
        }
    }

    private static func map(_ error: Error) -> GroupCloudError {
        if let own = error as? GroupCloudError { return own }
        if let cloud = error as? CKError {
            switch cloud.code {
            case .notAuthenticated, .managedAccountRestricted:
                return .iCloudUnavailable
            default:
                return .unreachable
            }
        }
        return .unreachable
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit))
    }
}

struct CloudGroup {
    var id: UUID
    var name: String
    var subject: String
    var inviteCode: String
    var memberNames: [String]
    var colorIndex: Int
    var createdAt: Date

    init?(record: CKRecord) {
        guard let rawID = record["groupUUID"] as? String,
              let id = UUID(uuidString: rawID),
              let name = record["name"] as? String,
              let invite = record["inviteCode"] as? String
        else { return nil }
        self.id = id
        self.name = name
        self.subject = record["subject"] as? String ?? "Общее"
        self.inviteCode = invite
        let joined = record["memberNames"] as? String ?? ""
        self.memberNames = joined.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        self.colorIndex = (record["colorIndex"] as? NSNumber)?.intValue ?? 0
        self.createdAt = record["createdAt"] as? Date ?? Date()
    }
}

struct CloudNote {
    var id: UUID
    var groupID: UUID
    var title: String
    var body: String
    var subject: String
    var summary: String
    var sourceFileName: String
    var colorIndex: Int
    var updatedAt: Date

    init?(record: CKRecord) {
        guard let rawID = record["noteUUID"] as? String,
              let id = UUID(uuidString: rawID),
              let rawGroup = record["groupUUID"] as? String,
              let groupID = UUID(uuidString: rawGroup)
        else { return nil }
        self.id = id
        self.groupID = groupID
        self.title = record["title"] as? String ?? ""
        self.body = record["body"] as? String ?? ""
        self.subject = record["subject"] as? String ?? "Общее"
        self.summary = record["summary"] as? String ?? ""
        self.sourceFileName = record["sourceFileName"] as? String ?? ""
        self.colorIndex = (record["colorIndex"] as? NSNumber)?.intValue ?? 0
        self.updatedAt = record["updatedAt"] as? Date ?? Date()
    }
}

enum GroupCloudError: LocalizedError {
    case iCloudUnavailable, unreachable, notFound

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            "Чтобы войти в группу с другого устройства, на нём должен быть включён iCloud."
        case .unreachable:
            "Не удалось связаться с iCloud. Проверьте сеть и повторите."
        case .notFound:
            "Группа с таким кодом не найдена. Проверьте код у того, кто вас пригласил."
        }
    }
}
