import SwiftUI
import SwiftData

struct NoteEditorView: View {
    @Bindable var note: Note
    var startsEditing: Bool = false

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(AppSettings.self) private var settings
    @Environment(AIAssistant.self) private var assistant

    @Query private var groups: [StudyGroup]

    @State private var isEditing: Bool
    @State private var activeTask: AITask?
    /// Текст конспекта до структурирования — чтобы правку ИИ можно было откатить.
    @State private var undoSnapshot: String?
    @State private var selectedTerm: MedicalTerm?
    @State private var errorMessage: String?
    @State private var showStudyMode = false
    @State private var showExamMode = false
    @State private var showPaywall = false
    @State private var showDeleteConfirmation = false
    @FocusState private var bodyFocused: Bool

    private enum AITask: String, Identifiable {
        case structure, summary, flashcards
        var id: String { rawValue }
        var label: String {
            switch self {
            case .structure: "Структурирую конспект…"
            case .summary: "Делаю выжимку…"
            case .flashcards: "Собираю карточки…"
            }
        }
    }

    init(note: Note, startsEditing: Bool = false) {
        self.note = note
        self.startsEditing = startsEditing
        _isEditing = State(initialValue: startsEditing)
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleBlock
                    aiToolbar
                    if let activeTask { processingBanner(activeTask) }
                    if undoSnapshot != nil { undoBanner }
                    if !note.summary.isEmpty { summaryCard }
                    bodyBlock
                    if !note.flashcards.isEmpty { flashcardsSection }
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .readableWidth()
            }
            // Клавиатура закрывается протягиванием списка — иначе на iPhone
            // она перекрывает половину конспекта и убрать её нечем.
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(isEditing ? "Редактирование" : note.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Готово" : "Править") {
                    if isEditing { save() }
                    withAnimation { isEditing.toggle() }
                }
                .fontWeight(.semibold)
                .keyboardShortcut(isEditing ? .return : "e", modifiers: .command)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    note.isPinned.toggle()
                    save()
                } label: {
                    Label(note.isPinned ? "Открепить" : "Закрепить",
                          systemImage: note.isPinned ? "pin.slash" : "pin")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                ShareLink(item: shareText) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    Clipboard.copy(shareText)
                } label: {
                    Label("Скопировать текст", systemImage: "doc.on.doc")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Удалить конспект", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Удалить «\(note.displayTitle)»?",
                            isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { deleteNote() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(note.flashcards.isEmpty
                 ? "Конспект будет удалён безвозвратно."
                 : "Конспект и \(pluralRu(note.flashcards.count, "связанная карточка", "связанные карточки", "связанных карточек")) будут удалены безвозвратно.")
        }
        .sheet(item: $selectedTerm) { TermSheet(term: $0).macSheetSize(height: 560) }
        .sheet(isPresented: $showStudyMode) { FlashcardStudyView(cards: note.flashcards).macSheetSize(height: 560) }
        .sheet(isPresented: $showExamMode) { ExamQuizView(cards: note.flashcards).macSheetSize(height: 640) }
        .sheet(isPresented: $showPaywall) { PaywallView().macSheetSize(height: 700) }
        .alert("Не получилось", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Понятно") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear { save() }
    }

    // MARK: - Заголовок и метаданные

    private var titleBlock: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                if isEditing {
                    TextField("Название конспекта", text: $note.title, axis: .vertical)
                        .font(.title3.bold())
                        .textFieldStyle(.plain)
                } else {
                    Text(note.displayTitle)
                        .font(.title3.bold())
                        .foregroundStyle(Theme.textPrimary)
                }

                HStack(spacing: 8) {
                    if isEditing {
                        TextField("Предмет", text: $note.subject)
                            .font(.caption)
                            .textFieldStyle(.plain)
                            .padding(.vertical, 5).padding(.horizontal, 10)
                            .background(note.accentColor.opacity(0.13), in: Capsule())
                            .frame(maxWidth: 160)
                    } else {
                        TagChip(text: note.subject, color: note.accentColor)
                    }

                    if let group = groups.first(where: { $0.id == note.groupID }) {
                        TagChip(text: group.name, color: Theme.accentCyan, icon: "person.2.fill")
                    }
                    Spacer()
                    Text(pluralRu(note.wordCount, "слово", "слова", "слов"))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }

                if isEditing {
                    HStack(spacing: 2) {
                        ForEach(0..<Theme.paletteColors.count, id: \.self) { idx in
                            Button {
                                note.colorIndex = idx
                            } label: {
                                Circle()
                                    .fill(Theme.paletteColor(idx))
                                    .frame(width: 24, height: 24)
                                    .overlay {
                                        if note.colorIndex == idx {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    // Кружок остаётся маленьким, но нажимаемая
                                    // область дотягивается до минимальных 44 pt.
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Цвет \(idx + 1)")
                            .accessibilityAddTraits(note.colorIndex == idx ? [.isSelected, .isButton] : .isButton)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Панель ИИ

    private var aiToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                aiButton("Структурировать", icon: "wand.and.stars", task: .structure)
                aiButton("Выжимка", icon: "text.line.first.and.arrowtriangle.forward", task: .summary)
                aiButton("Флеш-карты", icon: "rectangle.on.rectangle.angled", task: .flashcards)

                if !note.flashcards.isEmpty {
                    Button {
                        showStudyMode = true
                    } label: {
                        Label("Учить (\(note.flashcards.count))", systemImage: "graduationcap.fill")
                    }
                    .buttonStyle(SoftButtonStyle())

                    Button {
                        showExamMode = true
                    } label: {
                        Label("Экзамен", systemImage: "checkmark.seal.fill")
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func aiButton(_ title: String, icon: String, task: AITask) -> some View {
        Button {
            run(task)
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(SoftButtonStyle())
        .disabled(activeTask != nil)
    }

    private func processingBanner(_ task: AITask) -> some View {
        HStack(spacing: 11) {
            ProgressView().controlSize(.small).tint(Theme.primary)
            Text(task.label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(13)
        .background(Theme.chipGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var undoBanner: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
            Text("Конспект структурирован")
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Вернуть") {
                if let undoSnapshot {
                    note.body = undoSnapshot
                    save()
                }
                withAnimation { undoSnapshot = nil }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.primary)

            Button {
                withAnimation { undoSnapshot = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .background(Theme.success.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Выжимка

    private var summaryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accentPink)
                    Text("Краткая выжимка")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button {
                        note.summary = ""
                        save()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textSecondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Удалить выжимку")
                }
                MedicalTextView(text: note.summary, highlightTerms: settings.termHintsEnabled) {
                    selectedTerm = $0
                }
            }
        }
    }

    // MARK: - Тело конспекта

    private var bodyBlock: some View {
        GlassCard {
            if isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Текст конспекта")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    TextEditor(text: $note.body)
                        .font(.body)
                        .frame(minHeight: 300)
                        .scrollContentBackground(.hidden)
                        .focused($bodyFocused)
                }
            } else if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Конспект пуст")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Вставьте текст лекции, а затем нажмите «Структурировать» — ассистент разложит материал по разделам.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Начать писать") {
                        withAnimation { isEditing = true }
                        bodyFocused = true
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            } else {
                MedicalTextView(text: note.body, highlightTerms: settings.termHintsEnabled) {
                    selectedTerm = $0
                }
            }
        }
    }

    // MARK: - Флеш-карты

    private var flashcardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Флеш-карты",
                          subtitle: pluralRu(note.flashcards.count, "карточка", "карточки", "карточек"),
                          actionTitle: "Учить") { showStudyMode = true }

            ForEach(note.flashcards) { card in
                GlassCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.question)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(card.answer)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        note.flashcards.removeAll { $0.id == card.id }
                        context.delete(card)
                        save()
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Действия

    @MainActor
    private func run(_ task: AITask) {
        let text = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "Сначала добавьте текст конспекта."
            return
        }
        // Ограничение бесплатного тарифа: ИИ-инструменты доступны в пробном периоде и Premium.
        guard settings.hasFullAccess || task == .summary else {
            showPaywall = true
            return
        }

        activeTask = task
        Task {
            defer { activeTask = nil }
            do {
                switch task {
                case .structure:
                    let result = try await assistant.structure(noteBody: text)
                    await MainActor.run {
                        undoSnapshot = note.body
                        note.body = result
                        save()
                    }
                case .summary:
                    let result = try await assistant.summarize(text)
                    await MainActor.run {
                        note.summary = result
                        save()
                    }
                case .flashcards:
                    let pairs = try await assistant.makeFlashcards(from: text)
                    await MainActor.run {
                        // Повторный запуск не должен плодить копии уже собранных карточек.
                        var existing = Set(note.flashcards.map { $0.question.normalizedForCompare })
                        var added = 0
                        for pair in pairs {
                            let key = pair.question.normalizedForCompare
                            guard !key.isEmpty, !existing.contains(key) else { continue }
                            existing.insert(key)
                            note.flashcards.append(Flashcard(question: pair.question, answer: pair.answer))
                            added += 1
                        }
                        save()
                        if added == 0 {
                            errorMessage = "Новых карточек не нашлось — все уже добавлены."
                        }
                    }
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func save() {
        // Конспект мог быть удалён из списка, пока редактор ещё на экране:
        // запись в удалённую модель роняет SwiftData.
        guard !note.isDeleted else { return }
        note.updatedAt = Date()
        try? context.save()
    }

    private func deleteNote() {
        context.delete(note)
        try? context.save()
        dismiss()
    }

    private var shareText: String {
        var parts = ["# \(note.displayTitle)", "Предмет: \(note.subject)"]
        if !note.summary.isEmpty { parts.append("## Выжимка\n\(note.summary)") }
        if !note.body.isEmpty { parts.append(note.body) }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Режим заучивания

struct FlashcardStudyView: View {
    let cards: [Flashcard]

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var isFlipped = false
    @State private var correct = 0

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                if cards.isEmpty {
                    EmptyStateView(icon: "rectangle.on.rectangle.angled",
                                   title: "Карточек нет",
                                   message: "Сгенерируйте флеш-карты из конспекта.")
                } else if index >= cards.count {
                    resultView
                } else {
                    VStack(spacing: 22) {
                        BrandProgressBar(value: Double(index) / Double(cards.count))
                            .padding(.horizontal, 24)

                        Text("Карточка \(index + 1) из \(cards.count)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)

                        card(cards[index])
                            .padding(.horizontal, 22)

                        Spacer()

                        if isFlipped {
                            HStack(spacing: 12) {
                                Button {
                                    advance(wasCorrect: false)
                                } label: {
                                    Label("Ещё повторить", systemImage: "arrow.counterclockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(SoftButtonStyle(expands: true))

                                Button {
                                    advance(wasCorrect: true)
                                } label: {
                                    Label("Знаю", systemImage: "checkmark")
                                }
                                .buttonStyle(BrandButtonStyle(expands: true))
                            }
                            .padding(.horizontal, 22)
                        } else {
                            Button("Показать ответ") {
                                withAnimation(.spring) { isFlipped = true }
                            }
                            .buttonStyle(BrandButtonStyle())
                            .padding(.horizontal, 22)
                        }
                        Color.clear.frame(height: 8)
                    }
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Повторение")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    private func card(_ flashcard: Flashcard) -> some View {
        GlassCard(padding: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text(isFlipped ? "ОТВЕТ" : "ВОПРОС")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isFlipped ? Theme.accentPink : Theme.primary)
                Text(isFlipped ? flashcard.answer : flashcard.question)
                    .font(.title3)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        }
        .onTapGesture { withAnimation(.spring) { isFlipped.toggle() } }
    }

    private var resultView: some View {
        VStack(spacing: 18) {
            GradientIcon(systemName: "checkmark.seal.fill", size: 90)
            Text("Готово!")
                .font(.title.bold())
                .foregroundStyle(Theme.textPrimary)
            Text("Верно: \(correct) из \(cards.count)")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
            Button("Пройти заново") {
                index = 0
                correct = 0
                isFlipped = false
            }
            .buttonStyle(BrandButtonStyle(expands: false))
        }
        .padding(30)
    }

    private func advance(wasCorrect: Bool) {
        if wasCorrect { correct += 1 }
        // Интервальное повторение живёт в модели: здесь только сообщаем итог,
        // а следующая дата показа рассчитывается по схеме Лейтнера.
        cards[index].review(recalled: wasCorrect)
        withAnimation(.spring) {
            isFlipped = false
            index += 1
        }
    }
}
