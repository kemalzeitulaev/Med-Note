import SwiftUI
import SwiftData

struct NotesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isWideLayout) private var isWide

    @Query(sort: \Note.updatedAt, order: .reverse) private var allNotes: [Note]
    @Query private var groups: [StudyGroup]

    @State private var search = ""
    @State private var selectedSubject: String? = nil
    @State private var newNote: Note?
    /// Выбранный конспект в широкой раскладке (правая колонка).
    ///
    /// Храним идентификатор, а не сам объект: если конспект удалят из другой
    /// вкладки или вычистят как пустой, ссылка на удалённую модель уронит
    /// приложение при первом же обращении, а идентификатор просто не найдётся.
    @State private var selectedNoteID: UUID?
    @State private var notePendingDeletion: Note?

    private var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return allNotes.first { $0.id == selectedNoteID }
    }

    private var subjects: [String] {
        Array(Set(allNotes.map(\.subject))).sorted()
    }

    private var filtered: [Note] {
        var items = allNotes
        if let selectedSubject {
            items = items.filter { $0.subject == selectedSubject }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            items = items.filter {
                $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q) || $0.subject.lowercased().contains(q)
            }
        }
        return items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var body: some View {
        Group {
            if isWide {
                NavigationSplitView {
                    listColumn
                        .listColumnWidth()
                } detail: {
                    detailColumn
                }
            } else {
                NavigationStack {
                    listColumn
                }
            }
        }
        .sheet(item: $newNote, onDismiss: purgeAfterEditor) { note in
            NavigationStack { NoteEditorView(note: note, startsEditing: true) }
                .macSheetSize()
        }
        .confirmationDialog(
            notePendingDeletion.map { "Удалить «\($0.displayTitle)»?" } ?? "Удалить конспект?",
            isPresented: Binding(
                get: { notePendingDeletion != nil },
                set: { if !$0 { notePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let note = notePendingDeletion { delete(note) }
                notePendingDeletion = nil
            }
            Button("Отмена", role: .cancel) { notePendingDeletion = nil }
        } message: {
            Text(deletionMessage)
        }
    }

    private var deletionMessage: String {
        guard let note = notePendingDeletion else { return "" }
        let cards = note.flashcards.count
        return cards > 0
            ? "Конспект и \(pluralRu(cards, "связанная карточка", "связанные карточки", "связанных карточек")) будут удалены безвозвратно."
            : "Конспект будет удалён безвозвратно."
    }

    // MARK: - Список

    private var listColumn: some View {
        ZStack {
            AppBackground()

            List {
                subjectFilter
                    .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 6, trailing: 18))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if filtered.isEmpty {
                    EmptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: allNotes.isEmpty ? "Конспектов пока нет" : "Ничего не найдено",
                        message: allNotes.isEmpty
                            ? "Создайте первый конспект — ИИ структурирует материал и соберёт из него флеш-карты."
                            : "Попробуйте изменить запрос или снять фильтр по предмету.",
                        actionTitle: allNotes.isEmpty ? "Создать конспект" : nil,
                        action: allNotes.isEmpty ? { createNote() } : nil
                    )
                    .padding(.top, 24)
                    .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filtered) { note in
                        noteRow(note)
                            .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .contextMenu {
                                Button {
                                    note.isPinned.toggle()
                                    try? context.save()
                                } label: {
                                    Label(note.isPinned ? "Открепить" : "Закрепить",
                                          systemImage: note.isPinned ? "pin.slash" : "pin")
                                }
                                Button {
                                    Clipboard.copy(exportText(for: note))
                                } label: {
                                    Label("Скопировать текст", systemImage: "doc.on.doc")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    notePendingDeletion = note
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    notePendingDeletion = note
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Конспекты")
        .searchable(text: $search, prompt: "Поиск по конспектам")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: createNote) {
                    Label("Новый", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private func noteRow(_ note: Note) -> some View {
        if isWide {
            Button {
                selectedNoteID = note.id
            } label: {
                NoteRow(note: note,
                        groupName: groupName(for: note),
                        isSelected: selectedNoteID == note.id)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink { NoteEditorView(note: note) } label: {
                NoteRow(note: note, groupName: groupName(for: note))
            }
            .buttonStyle(.plain)
        }
    }

    private func exportText(for note: Note) -> String {
        var parts = ["# \(note.displayTitle)", "Предмет: \(note.subject)"]
        if !note.summary.isEmpty { parts.append("## Выжимка\n\(note.summary)") }
        if !note.body.isEmpty { parts.append(note.body) }
        return parts.joined(separator: "\n\n")
    }

    private func delete(_ note: Note) {
        if selectedNoteID == note.id { selectedNoteID = nil }
        context.delete(note)
        try? context.save()
    }

    /// После закрытия редактора убираем пустышки, но щадим конспект,
    /// который остался открытым в правой колонке сплит-вью.
    private func purgeAfterEditor() {
        context.purgeBlankNotes(keeping: selectedNote)
    }

    // MARK: - Деталь

    @ViewBuilder
    private var detailColumn: some View {
        if let selectedNote {
            NoteEditorView(note: selectedNote)
                .id(selectedNote.id)
        } else {
            ZStack {
                AppBackground()
                EmptyStateView(
                    icon: "doc.text",
                    title: "Выберите конспект",
                    message: filtered.isEmpty
                        ? "Создайте первый конспект — ассистент поможет его структурировать."
                        : "Слева список ваших конспектов. Откройте любой, чтобы читать и работать с ИИ.",
                    actionTitle: "Новый конспект",
                    action: { createNote() }
                )
                .readableWidth(460)
            }
        }
    }

    // MARK: - Фильтр по предметам

    private var subjectFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "Все", isOn: selectedSubject == nil) { selectedSubject = nil }
                ForEach(subjects, id: \.self) { subject in
                    FilterChip(title: subject, isOn: selectedSubject == subject) {
                        selectedSubject = selectedSubject == subject ? nil : subject
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func groupName(for note: Note) -> String? {
        guard let gid = note.groupID else { return nil }
        return groups.first { $0.id == gid }?.name
    }

    private func createNote() {
        // Пустой конспект, оставшийся с прошлого раза, переиспользуем,
        // иначе список постепенно зарастает безымянными заготовками.
        context.purgeBlankNotes(keeping: selectedNote)
        let note = Note(subject: selectedSubject ?? "Общее", colorIndex: Int.random(in: 0..<8))
        context.insert(note)
        if isWide {
            selectedNoteID = note.id
        } else {
            newNote = note
        }
    }
}

// MARK: - Строка конспекта

struct NoteRow: View {
    let note: Note
    var groupName: String? = nil
    var isSelected: Bool = false

    var body: some View {
        GlassCard(isHighlighted: isSelected) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(note.accentColor)
                        .frame(width: 9, height: 9)
                    Text(note.displayTitle)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.accentPink)
                    }
                }

                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    TagChip(text: note.subject, color: note.accentColor)
                    if let groupName {
                        TagChip(text: groupName, color: Theme.accentCyan, icon: "person.2.fill")
                    }
                    if !note.flashcards.isEmpty {
                        TagChip(text: "\(note.flashcards.count)", color: Theme.primary, icon: "rectangle.on.rectangle.angled")
                    }
                    Spacer()
                    Text(note.updatedAt.localizedRelative)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isOn ? .white : Theme.textSecondary)
                .padding(.vertical, 8)
                .padding(.horizontal, 15)
                .background {
                    if isOn {
                        Capsule().fill(Theme.brandGradient)
                    } else {
                        Capsule().fill(Theme.cardFill(scheme))
                            .overlay(Capsule().stroke(Theme.hairline.opacity(scheme == .dark ? 0.25 : 0.9), lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
