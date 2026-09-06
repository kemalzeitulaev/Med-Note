import SwiftUI
import SwiftData

struct StudyCalendarView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isWideLayout) private var isWide

    @Query(sort: \StudyEvent.date) private var events: [StudyEvent]

    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var weekOffset = 0
    @State private var showAddEvent = false

    private let calendar = Calendar.current

    private var weekDays: [Date] {
        let base = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: Date()) ?? Date()
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: base) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private var dayEvents: [StudyEvent] {
        events.filter { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private var upcoming: [StudyEvent] {
        events.filter { $0.date > Date() && !$0.isDone }.prefix(4).map { $0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 16) {
                        weekStrip

                        if isWide {
                            // На широком экране расписание дня и ближайшие
                            // события удобнее видеть рядом, а не листая вниз.
                            HStack(alignment: .top, spacing: 18) {
                                daySection
                                if !upcoming.isEmpty { upcomingSection }
                            }
                        } else {
                            daySection
                            if weekOffset == 0 && !upcoming.isEmpty { upcomingSection }
                        }
                        Color.clear.frame(height: 12)
                    }
                    .padding(.horizontal, isWide ? 24 : 18)
                    .readableWidth(isWide ? 1100 : Layout.contentMaxWidth)
                }
            }
            .navigationTitle("Календарь")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showAddEvent = true } label: {
                        Label("Добавить", systemImage: "plus")
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                }
            }
            .sheet(isPresented: $showAddEvent) {
                EventEditorView(defaultDate: selectedDate)
                    .macSheetSize(height: 480)
            }
        }
    }

    // MARK: - Полоска недели

    private var weekStrip: some View {
        GlassCard(padding: 14) {
            VStack(spacing: 12) {
                HStack {
                    Button {
                        withAnimation { weekOffset -= 1 }
                    } label: {
                        Image(systemName: "chevron.left").foregroundStyle(Theme.primary)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    Text(monthTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()

                    Button {
                        withAnimation { weekOffset += 1 }
                    } label: {
                        Image(systemName: "chevron.right").foregroundStyle(Theme.primary)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 5) {
                    ForEach(weekDays, id: \.self) { day in
                        dayCell(day)
                    }
                }
            }
        }
    }

    /// Если неделя попадает на стык месяцев, показываем оба: «авг. — сентябрь 2026».
    private var monthTitle: String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        let fullLast = last.localized(.dateTime.month(.wide).year()).capitalizedFirst
        guard calendar.component(.month, from: first) != calendar.component(.month, from: last) else {
            return fullLast
        }
        let shortFirst = first.localized(.dateTime.month(.abbreviated))
        return "\(shortFirst) — \(fullLast.lowercasedFirst)"
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)
        let count = events.filter { calendar.isDate($0.date, inSameDayAs: day) }.count

        return Button {
            withAnimation(.spring(duration: 0.25)) { selectedDate = day }
        } label: {
            VStack(spacing: 4) {
                Text(day.localized(.dateTime.weekday(.abbreviated)))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : Theme.textSecondary)
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : (isToday ? Theme.primary : Theme.textPrimary))
                HStack(spacing: 2) {
                    ForEach(0..<min(count, 3), id: \.self) { _ in
                        Circle()
                            .fill(isSelected ? Color.white : Theme.primarySoft)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.brandGradient)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceTint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - События дня

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: dayTitle,
                subtitle: dayEvents.isEmpty
                    ? "Свободный день"
                    : pluralRu(dayEvents.count, "событие", "события", "событий")
            )

            if dayEvents.isEmpty {
                GlassCard {
                    HStack(spacing: 12) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.primarySoft)
                        Text("Занятий не запланировано. Можно добавить блок самоподготовки.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            } else {
                ForEach(dayEvents) { event in
                    EventRow(event: event)
                        .contextMenu {
                            Button {
                                event.isDone.toggle()
                            } label: {
                                Label(event.isDone ? "Вернуть в план" : "Отметить выполненным",
                                      systemImage: event.isDone ? "arrow.uturn.backward" : "checkmark")
                            }
                            Button(role: .destructive) {
                                context.delete(event)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    private var dayTitle: String {
        if calendar.isDateInToday(selectedDate) { return "Сегодня" }
        if calendar.isDateInTomorrow(selectedDate) { return "Завтра" }
        return selectedDate.localized(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst
    }

    // MARK: - Ближайшее

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Ближайшее", subtitle: "Что ждёт впереди")
            ForEach(upcoming) { event in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(event.kind.color)
                        .frame(width: 4, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(event.date.localized(.dateTime.day().month(.abbreviated).hour().minute()))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    TagChip(text: event.kind.title, color: event.kind.color)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.cardFill(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

// MARK: - Строка события

struct EventRow: View {
    @Bindable var event: StudyEvent

    var body: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 13) {
                VStack(spacing: 2) {
                    Text(event.date.localized(.dateTime.hour().minute()))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(event.kind.color)
                }
                .frame(width: 48)

                Rectangle()
                    .fill(event.kind.color.opacity(0.3))
                    .frame(width: 1, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(event.isDone ? Theme.textSecondary : Theme.textPrimary)
                        .strikethrough(event.isDone)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Label(event.kind.title, systemImage: event.kind.icon)
                            .font(.caption2)
                            .foregroundStyle(event.kind.color)
                        if !event.place.isEmpty {
                            Text("· \(event.place)")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                Spacer()

                Button {
                    withAnimation { event.isDone.toggle() }
                } label: {
                    Image(systemName: event.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(event.isDone ? Theme.success : Theme.hairline)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Создание события

struct EventEditorView: View {
    let defaultDate: Date

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var kind: StudyEventKind = .lecture
    @State private var date: Date
    @State private var place = ""
    @State private var details = ""
    @State private var remind = true

    init(defaultDate: Date) {
        self.defaultDate = defaultDate
        let cal = Calendar.current
        let hour = cal.component(.hour, from: Date()) + 1
        _date = State(initialValue: cal.date(bySettingHour: min(hour, 22), minute: 0, second: 0, of: defaultDate) ?? defaultDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Событие") {
                    TextField("Название", text: $title)
                    Picker("Тип", selection: $kind) {
                        ForEach(StudyEventKind.allCases) { k in
                            Label(k.title, systemImage: k.icon).tag(k)
                        }
                    }
                    DatePicker("Дата и время", selection: $date)
                }
                Section("Детали") {
                    TextField("Место (аудитория, кафедра)", text: $place)
                    TextField("Заметка", text: $details, axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("Напомнить заранее", isOn: $remind)
                }
            }
            .navigationTitle("Новое событие")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let event = StudyEvent(title: title, date: date, kind: kind, place: place, details: details)
        event.remindMe = remind
        context.insert(event)
        try? context.save()
        dismiss()
    }
}
