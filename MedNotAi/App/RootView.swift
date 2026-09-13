import SwiftUI
import SwiftData

enum AppTab: Hashable, CaseIterable {
    case home, notes, chat, calendar, groups

    var title: String {
        switch self {
        case .home: "Главная"
        case .notes: "Конспекты"
        case .chat: "Ассистент"
        case .calendar: "Календарь"
        case .groups: "Группы"
        }
    }

    var icon: String {
        switch self {
        case .home: "square.grid.2x2.fill"
        case .notes: "doc.text.fill"
        case .chat: "sparkles"
        case .calendar: "calendar"
        case .groups: "person.2.fill"
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var settings = AppSettings.shared
    @State private var auth = AuthService.shared
    @State private var selection: AppTab = RootView.initialTab

    @Query private var events: [StudyEvent]

    var body: some View {
        Group {
            if !settings.hasSeenOnboarding {
                OnboardingView()
            } else if auth.isSignedIn || settings.hasSkippedSignIn {
                mainTabs
            } else {
                SignInView(allowsSkip: true)
            }
        }
        .environment(settings)
        .environment(AIAssistant.shared)
        .environment(auth)
        .environment(\.locale, Locale(identifier: settings.language.localeIdentifier))
        .tint(Theme.primary)
        .animation(.spring(duration: 0.35), value: auth.isSignedIn || settings.hasSkippedSignIn)
        .task {
            await auth.refreshAppleCredentialState()
        }
        // Расписание уведомлений пересобирается при любом изменении событий
        // и настроек: раньше переключатель «Напоминать заранее» только
        // сохранялся, но ничего не планировал.
        .task(id: reminderSignature) {
            await StudyReminders.shared.sync(with: events)
        }
    }

    /// Меняется, когда меняется что-либо влияющее на расписание напоминаний.
    private var reminderSignature: String {
        let events = events
            .map { "\($0.id)-\($0.date.timeIntervalSince1970)-\($0.isDone)-\($0.remindMe)" }
            .joined(separator: "|")
        return "\(settings.remindersEnabled)-\(settings.reminderLeadMinutes)-\(events)"
    }

    /// Позволяет открыть приложение сразу на нужной вкладке через launch-аргумент `-initialTab notes`.
    private static var initialTab: AppTab {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "initialTab") {
        case "notes": return .notes
        case "chat": return .chat
        case "calendar": return .calendar
        case "groups": return .groups
        default: return .home
        }
        #else
        return .home
        #endif
    }

    /// На iPhone — таб-бар снизу, на iPad и Mac тот же TabView превращается в сайдбар.
    private var mainTabs: some View {
        TabView(selection: $selection) {
            Tab(AppTab.home.title, systemImage: AppTab.home.icon, value: AppTab.home) {
                HomeView(selection: $selection)
            }
            Tab(AppTab.notes.title, systemImage: AppTab.notes.icon, value: AppTab.notes) {
                NotesView()
            }
            Tab(AppTab.chat.title, systemImage: AppTab.chat.icon, value: AppTab.chat) {
                ChatListView()
            }
            Tab(AppTab.calendar.title, systemImage: AppTab.calendar.icon, value: AppTab.calendar) {
                StudyCalendarView()
            }
            Tab(AppTab.groups.title, systemImage: AppTab.groups.icon, value: AppTab.groups) {
                GroupsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .measuredWidth()
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Note.self, Flashcard.self, StudyEvent.self, ChatThread.self, ChatMessage.self, StudyGroup.self, LectureRecording.self], inMemory: true)
}
