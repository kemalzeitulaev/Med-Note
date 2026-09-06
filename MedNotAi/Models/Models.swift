import Foundation
import SwiftData
import SwiftUI

// MARK: - Конспект

@Model
final class Note {
    var id: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var subject: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isPinned: Bool = false
    var colorIndex: Int = 0
    /// Краткая выжимка, сгенерированная ИИ.
    var summary: String = ""
    /// Идентификатор учебной группы, если конспект общий.
    var groupID: UUID?

    /// Обратная связь объявлена явно: без неё SwiftData не знал, что карточка
    /// принадлежит конспекту, и удалённые карточки оставались в базе сиротами.
    @Relationship(deleteRule: .cascade, inverse: \Flashcard.note)
    var flashcards: [Flashcard] = []

    init(title: String = "", body: String = "", subject: String = "Общее", colorIndex: Int = 0, groupID: UUID? = nil) {
        self.id = UUID()
        self.title = title
        self.body = body
        self.subject = subject
        self.colorIndex = colorIndex
        self.groupID = groupID
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Без названия" : title
    }

    var preview: String {
        body.plainText
    }

    var wordCount: Int {
        body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var accentColor: Color { Theme.paletteColor(colorIndex) }

    /// Конспект создан, но так и не заполнен — такой не нужно хранить.
    var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && summary.isEmpty
            && flashcards.isEmpty
    }
}

extension ModelContext {
    /// Убирает конспекты, созданные по кнопке «+» и закрытые без единой правки.
    ///
    /// `keeping` защищает конспект, который прямо сейчас открыт в другой колонке:
    /// раньше метод сносил его вместе с остальными пустыми, и обращение к
    /// удалённому объекту роняло приложение.
    func purgeBlankNotes(keeping survivor: Note? = nil) {
        guard let notes = try? fetch(FetchDescriptor<Note>()) else { return }
        var removed = false
        for note in notes where note.isBlank && note.id != survivor?.id {
            delete(note)
            removed = true
        }
        guard removed else { return }
        try? save()
    }

    /// Снимает у конспектов ссылку на группу, которой больше нет.
    /// `groupID` — обычный UUID, а не связь, поэтому SwiftData сам его не почистит.
    func detachNotes(fromGroup groupID: UUID) {
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.groupID == groupID })
        for note in (try? fetch(descriptor)) ?? [] {
            note.groupID = nil
        }
    }
}

// MARK: - Флеш-карта

@Model
final class Flashcard {
    var id: UUID = UUID()
    var question: String = ""
    var answer: String = ""
    var createdAt: Date = Date()
    var lastReviewed: Date?
    /// Сколько раз подряд ответ был верным.
    var streak: Int = 0
    /// Когда карточку стоит показать снова. Новая карточка ждёт первого показа.
    var dueDate: Date = Date.distantPast
    /// Текущий интервал повторения в днях.
    var intervalDays: Int = 0
    /// Конспект-владелец. Задаётся автоматически через обратную связь.
    var note: Note?

    init(question: String, answer: String) {
        self.id = UUID()
        self.question = question
        self.answer = answer
        self.createdAt = Date()
        self.dueDate = Date.distantPast
    }

    var isDue: Bool { dueDate <= Date() }

    var isNew: Bool { lastReviewed == nil }

    /// Интервальное повторение по упрощённой схеме Лейтнера:
    /// верный ответ растягивает паузу, ошибка возвращает карточку в начало.
    /// Дни подобраны под подготовку к сессии: 1 → 3 → 7 → 16 → 35 → 75.
    func review(recalled: Bool, now: Date = Date()) {
        if recalled {
            streak += 1
            intervalDays = Self.nextInterval(after: intervalDays)
        } else {
            streak = 0
            intervalDays = 0
        }
        lastReviewed = now
        // Ошибочную карточку показываем ещё раз в этот же день.
        dueDate = intervalDays == 0
            ? now.addingTimeInterval(10 * 60)
            : Calendar.current.date(byAdding: .day, value: intervalDays, to: now) ?? now
    }

    private static func nextInterval(after current: Int) -> Int {
        switch current {
        case 0: 1
        case 1: 3
        case 3: 7
        default: min(180, Int((Double(current) * 2.2).rounded()))
        }
    }
}

// MARK: - Событие в календаре

enum StudyEventKind: String, CaseIterable, Codable, Identifiable {
    case lecture, seminar, practice, exam, deadline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lecture: "Лекция"
        case .seminar: "Семинар"
        case .practice: "Практика"
        case .exam: "Экзамен"
        case .deadline: "Дедлайн"
        }
    }

    var icon: String {
        switch self {
        case .lecture: "person.wave.2.fill"
        case .seminar: "bubble.left.and.bubble.right.fill"
        case .practice: "stethoscope"
        case .exam: "graduationcap.fill"
        case .deadline: "flag.checkered"
        }
    }

    var color: Color {
        switch self {
        case .lecture: Theme.primary
        case .seminar: Color(hex: 0x0EA5E9)
        case .practice: Theme.success
        case .exam: Theme.danger
        case .deadline: Theme.warning
        }
    }
}

@Model
final class StudyEvent {
    var id: UUID = UUID()
    var title: String = ""
    var date: Date = Date()
    var kindRaw: String = StudyEventKind.lecture.rawValue
    var place: String = ""
    var details: String = ""
    var isDone: Bool = false
    var remindMe: Bool = true

    init(title: String, date: Date, kind: StudyEventKind, place: String = "", details: String = "") {
        self.id = UUID()
        self.title = title
        self.date = date
        self.kindRaw = kind.rawValue
        self.place = place
        self.details = details
    }

    var kind: StudyEventKind {
        get { StudyEventKind(rawValue: kindRaw) ?? .lecture }
        set { kindRaw = newValue.rawValue }
    }
}

// MARK: - Чат

enum ChatRole: String, Codable {
    case user, assistant
}

@Model
final class ChatMessage {
    var id: UUID = UUID()
    var roleRaw: String = ChatRole.user.rawValue
    var text: String = ""
    var createdAt: Date = Date()
    /// Ошибка сети/API, если ответ не получен.
    var isError: Bool = false
    /// Диалог-владелец. Задаётся автоматически через обратную связь.
    var thread: ChatThread?

    init(role: ChatRole, text: String, isError: Bool = false) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.text = text
        self.isError = isError
        self.createdAt = Date()
    }

    var role: ChatRole { ChatRole(rawValue: roleRaw) ?? .user }
}

@Model
final class ChatThread {
    var id: UUID = UUID()
    var title: String = "Новый диалог"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.thread)
    var messages: [ChatMessage] = []

    init(title: String = "Новый диалог") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var sortedMessages: [ChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    var lastPreview: String {
        sortedMessages.last?.text.plainText ?? "Пусто"
    }
}

// MARK: - Учебная группа

@Model
final class StudyGroup {
    var id: UUID = UUID()
    var name: String = ""
    var subject: String = ""
    var inviteCode: String = ""
    var memberNames: [String] = []
    var colorIndex: Int = 0
    var createdAt: Date = Date()

    init(name: String, subject: String, memberNames: [String] = [], colorIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.subject = subject
        self.memberNames = memberNames
        self.colorIndex = colorIndex
        self.inviteCode = StudyGroup.makeInviteCode()
        self.createdAt = Date()
    }

    var accentColor: Color { Theme.paletteColor(colorIndex) }

    static func makeInviteCode() -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
