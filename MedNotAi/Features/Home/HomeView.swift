import SwiftUI
import SwiftData

struct HomeView: View {
    @Binding var selection: AppTab

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.isWideLayout) private var isWide
    @Environment(\.storeRecoveryNotice) private var recoveryNotice

    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \StudyEvent.date) private var events: [StudyEvent]

    @State private var showPaywall = false
    @State private var showGlossary = false
    @State private var showReview = false
    @State private var showExam = false
    @State private var newNote: Note?

    private var dueCards: Int { ReviewQueue.dueCount(in: notes) }
    private var allCards: [Flashcard] { notes.flatMap(\.flashcards) }

    private var todayEvents: [StudyEvent] {
        let cal = Calendar.current
        return events.filter { cal.isDateInToday($0.date) }
    }

    private var upcomingDeadline: StudyEvent? {
        events.first { $0.date > Date() && ($0.kind == .deadline || $0.kind == .exam) && !$0.isDone }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    if isWide {
                        wideLayout
                    } else {
                        compactLayout
                    }
                }
            }
            .navigationTitle("MedNoteAi")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { ProfileView() } label: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.primary)
                    }
                    .accessibilityLabel("Профиль и настройки")
                }
            }
            .sheet(isPresented: $showPaywall) { PaywallView().macSheetSize(height: 700) }
            .sheet(isPresented: $showGlossary) { GlossaryView().macSheetSize(width: 720, height: 640) }
            .sheet(isPresented: $showReview) { ReviewView().macSheetSize(height: 620) }
            .sheet(isPresented: $showExam) { ExamQuizView(cards: allCards).macSheetSize(height: 640) }
            .sheet(item: $newNote, onDismiss: { context.purgeBlankNotes() }) { note in
                NavigationStack { NoteEditorView(note: note, startsEditing: true) }
                    .macSheetSize()
            }
        }
    }

    // MARK: - Раскладки

    private var compactLayout: some View {
        VStack(spacing: 18) {
            if let notice = recoveryNotice { recoveryBanner(notice) }
            header
            quickActions
            if dueCards > 0 { reviewCard }
            if !allCards.isEmpty { examCard }
            if let deadline = upcomingDeadline { deadlineCard(deadline) }
            todaySection
            recentNotesSection
            if settings.tier.showsAds { AdBanner(onUpgrade: { showPaywall = true }) }
            Color.clear.frame(height: 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .readableWidth()
    }

    /// На iPad и Mac экран шире — раскладываем в две колонки,
    /// чтобы расписание и конспекты были видны одновременно.
    private var wideLayout: some View {
        VStack(spacing: 18) {
            if let notice = recoveryNotice { recoveryBanner(notice) }
            header
            quickActions

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 18) {
                    if dueCards > 0 { reviewCard }
                    if !allCards.isEmpty { examCard }
                    if let deadline = upcomingDeadline { deadlineCard(deadline) }
                    todaySection
                }
                VStack(spacing: 18) {
                    recentNotesSection
                    if settings.tier.showsAds { AdBanner(onUpgrade: { showPaywall = true }) }
                }
            }
            Color.clear.frame(height: 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .readableWidth(1100)
    }

    // MARK: - Шапка

    private var header: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(greeting)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Text(settings.greetingName)
                            .font(.title2.bold())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Spacer()
                    statusBadge
                }

                HStack(spacing: 10) {
                    StatPill(value: "\(notes.count)", caption: "конспектов", icon: "doc.text.fill", color: Theme.primary)
                    StatPill(value: "\(notes.reduce(0) { $0 + $1.flashcards.count })", caption: "карточек", icon: "rectangle.on.rectangle.angled", color: Theme.accentPink)
                    StatPill(value: "\(todayEvents.count)", caption: "сегодня", icon: "calendar", color: Theme.accentCyan)
                }
            }
        }
    }

    /// Очередь повторения на сегодня. Стоит выше расписания: пропущенный
    /// день интервального повторения стоит дороже, чем пропущенная лекция.
    private var reviewCard: some View {
        Button {
            showReview = true
        } label: {
            GlassCard {
                HStack(spacing: 14) {
                    GradientIcon(systemName: "rectangle.on.rectangle.angled", size: 46,
                                 colors: [Color(hex: 0xF59E0B), Color(hex: 0xEC4899)])
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Повторение на сегодня")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(pluralRu(dueCards, "карточка ждёт", "карточки ждут", "карточек ждут")) повторения")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var examCard: some View {
        Button {
            showExam = true
        } label: {
            GlassCard {
                HStack(spacing: 14) {
                    GradientIcon(systemName: "checkmark.seal.fill", size: 46,
                                 colors: [Color(hex: 0x0EA5E9), Color(hex: 0x7C3AED)])
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Экзамен по карточкам")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Проверьте себя письменно — интервалы повторения не сдвинутся")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// База не открылась и была пересоздана — молчать об этом нельзя,
    /// иначе исчезновение конспектов выглядит как потеря данных без причины.
    private func recoveryBanner(_ notice: StoreRecoveryNotice) -> some View {
        GlassCard(padding: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: notice.isMemoryOnly ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(notice.isMemoryOnly ? Theme.danger : Theme.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(notice.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Доброе утро"
        case 12..<18: return "Добрый день"
        case 18..<23: return "Добрый вечер"
        default: return "Доброй ночи"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch settings.tier {
        case .premium:
            TagChip(text: "Premium", color: Theme.primary, icon: "crown.fill")
        case .promo:
            TagChip(text: settings.promoDaysLeft.map { "Промо · \($0) дн." } ?? "Промо-доступ",
                    color: Theme.success, icon: "ticket.fill")
        case .trial:
            Button { showPaywall = true } label: {
                // Истёкший триал раньше показывался как «Пробный · 0 дн.» —
                // выглядело как действующий доступ, хотя функции уже закрыты.
                TagChip(text: settings.trialDaysLeft > 0 ? "Пробный · \(settings.trialDaysLeft) дн." : "Пробный истёк",
                        color: settings.trialDaysLeft > 0 ? Theme.warning : Theme.danger,
                        icon: settings.trialDaysLeft > 0 ? "clock.fill" : "exclamationmark.circle.fill")
            }
            .buttonStyle(.plain)
        case .free:
            Button { showPaywall = true } label: {
                TagChip(text: "Улучшить", color: Theme.accentPink, icon: "sparkles")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Быстрые действия

    /// На iPhone — сетка 2×2, на широком экране все действия в один ряд.
    private var quickActions: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: isWide ? 4 : 2), spacing: 10) {
            QuickActionCard(icon: "square.and.pencil", title: "Новый конспект",
                            colors: [Color(hex: 0x7C3AED), Color(hex: 0xA855F7)]) {
                let note = Note(subject: "Общее", colorIndex: Int.random(in: 0..<8))
                context.insert(note)
                newNote = note
            }
            QuickActionCard(icon: "sparkles", title: "Спросить ИИ",
                            colors: [Color(hex: 0xA855F7), Color(hex: 0xEC4899)]) {
                selection = .chat
            }
            QuickActionCard(icon: "rectangle.on.rectangle.angled", title: "Повторение",
                            colors: [Color(hex: 0xF59E0B), Color(hex: 0xEC4899)]) {
                showReview = true
            }
            QuickActionCard(icon: "character.book.closed.fill", title: "Глоссарий",
                            colors: [Color(hex: 0x0EA5E9), Color(hex: 0x6366F1)]) {
                showGlossary = true
            }
        }
    }

    // MARK: - Ближайший дедлайн

    private func deadlineCard(_ event: StudyEvent) -> some View {
        GlassCard {
            HStack(spacing: 14) {
                GradientIcon(systemName: event.kind.icon, size: 46,
                             colors: [event.kind.color, event.kind.color.opacity(0.6)])
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.kind.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(event.kind.color)
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(relativeText(for: event.date))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
        }
    }

    private func relativeText(for date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Сегодня в " + date.localizedTime
        case 1: return "Завтра в " + date.localizedTime
        default: return "Через \(days) дн. · " + date.localized(Date.FormatStyle(date: .abbreviated, time: .shortened))
        }
    }

    // MARK: - Сегодня

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Сегодня", subtitle: Date().localized(.dateTime.weekday(.wide).day().month(.wide)),
                          actionTitle: "Календарь") { selection = .calendar }

            if todayEvents.isEmpty {
                GlassCard {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.success)
                        Text("На сегодня занятий нет. Отличный момент повторить материал.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            } else {
                ForEach(todayEvents) { event in
                    EventRow(event: event)
                }
            }
        }
    }

    // MARK: - Недавние конспекты

    private var recentNotesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Недавние конспекты", actionTitle: "Все") { selection = .notes }

            if notes.isEmpty {
                GlassCard {
                    Text("Пока пусто. Создайте первый конспект — ИИ поможет его структурировать.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                ForEach(notes.prefix(3)) { note in
                    NavigationLink { NoteEditorView(note: note) } label: {
                        NoteRow(note: note)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Вспомогательные вью

struct StatPill: View {
    let value: String
    let caption: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(value).font(.headline)
            }
            .foregroundStyle(color)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct QuickActionCard: View {
    let icon: String
    let title: String
    let colors: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: colors[0].opacity(0.3), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }
}

/// Рекламный блок для бесплатного тарифа — часть модели монетизации.
struct AdBanner: View {
    let onUpgrade: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "megaphone.fill")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Реклама")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                Text("Отключите рекламу и откройте все функции в Premium")
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            Button("$7/мес", action: onUpgrade)
                .buttonStyle(SoftButtonStyle())
        }
        .padding(14)
        .background(Theme.surfaceTint.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(Theme.hairline)
        )
    }
}
