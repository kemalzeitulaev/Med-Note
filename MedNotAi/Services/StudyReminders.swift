import Foundation
import UserNotifications

/// Локальные напоминания о занятиях и дедлайнах.
/// Работают без интернета и одинаково на iPhone, iPad и Mac.
@MainActor
final class StudyReminders {
    static let shared = StudyReminders()

    private let center = UNUserNotificationCenter.current()
    private let settings = AppSettings.shared

    private init() {}

    // MARK: - Разрешение

    enum Permission {
        case granted, denied, undetermined
    }

    func permission() async -> Permission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    /// Спрашивает разрешение, если пользователь ещё не отвечал.
    @discardableResult
    func requestPermission() async -> Bool {
        switch await permission() {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    // MARK: - Планирование

    /// Переписывает расписание уведомлений целиком: так проще держать его
    /// в согласии с базой, чем отслеживать каждое изменение по отдельности.
    func sync(with events: [StudyEvent]) async {
        center.removeAllPendingNotificationRequests()

        guard settings.remindersEnabled, await permission() == .granted else { return }

        // Система ограничивает число запланированных уведомлений, поэтому берём ближайшие.
        let upcoming = events
            .filter { !$0.isDone && $0.remindMe && $0.date > Date() }
            .sorted { $0.date < $1.date }
            .prefix(30)

        for event in upcoming {
            for reminder in reminders(for: event) {
                await add(reminder)
            }
        }
    }

    /// Какие уведомления полагаются событию.
    /// К паре и семинару достаточно напомнить незадолго до начала,
    /// а про экзамен и дедлайн полезно узнать ещё накануне вечером.
    private func reminders(for event: StudyEvent) -> [Reminder] {
        var result: [Reminder] = []
        let lead = TimeInterval(settings.reminderLeadMinutes * 60)

        let leadDate = event.date.addingTimeInterval(-lead)
        if leadDate > Date() {
            result.append(Reminder(
                id: "event-\(event.id.uuidString)-lead",
                date: leadDate,
                title: event.title,
                body: leadBody(for: event)
            ))
        }

        if event.kind == .exam || event.kind == .deadline,
           let evening = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0,
                                               of: event.date.addingTimeInterval(-86_400)),
           evening > Date(), evening < leadDate {
            result.append(Reminder(
                id: "event-\(event.id.uuidString)-eve",
                date: evening,
                title: "Завтра: \(event.title)",
                body: event.kind == .exam ? "Хороший момент повторить конспекты и карточки." : "Остались сутки до дедлайна."
            ))
        }

        return result
    }

    private func leadBody(for event: StudyEvent) -> String {
        var parts = ["\(event.kind.title) в \(event.date.localizedTime)"]
        if !event.place.isEmpty { parts.append(event.place) }
        return parts.joined(separator: " · ")
    }

    private struct Reminder {
        let id: String
        let date: Date
        let title: String
        let body: String
    }

    private func add(_ reminder: Reminder) async {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
        let request = UNNotificationRequest(
            identifier: reminder.id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        try? await center.add(request)
    }

    /// Сколько напоминаний реально стоит в очереди — показываем в настройках.
    func pendingCount() async -> Int {
        await center.pendingNotificationRequests().count
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }
}
