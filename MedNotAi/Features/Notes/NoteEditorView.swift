import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(PhotosUI)
import PhotosUI
#endif

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
    @State private var showDeleteConfirmation = false
    @State private var showRecorder = false
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var previewPhoto: NotePhoto?
    @State private var player = LecturePlayer()
    @State private var showAttachPhotos = false
    #if os(iOS)
    @State private var showCamera = false
    #endif
    #if canImport(PhotosUI)
    @State private var slidePhotos: [PhotosPickerItem] = []
    @State private var notePhotos: [PhotosPickerItem] = []
    #endif
    @FocusState private var focusedBlockID: UUID?

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
                    if isImporting { processingBannerCustom("Разбираю лекцию…") }
                    if undoSnapshot != nil { undoBanner }
                    if !note.summary.isEmpty { summaryCard }
                    if !note.recordings.isEmpty || !note.sourceFileName.isEmpty { sourcesCard }
                    if !note.photos.isEmpty || isEditing { photosSection }
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
                Button {
                    showRecorder = true
                } label: {
                    Label("Записать лекцию", systemImage: "mic.fill")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("Импорт PDF или слайдов", systemImage: "doc.badge.plus")
                }
            }
            #if canImport(PhotosUI)
            ToolbarItem(placement: .secondaryAction) {
                PhotosPicker(selection: $notePhotos, maxSelectionCount: 8, matching: .images) {
                    Label("Добавить фото", systemImage: "photo.badge.plus")
                }
            }
            #endif
            #if os(iOS)
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showCamera = true
                } label: {
                    Label("Снять фото", systemImage: "camera.fill")
                }
            }
            #endif
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
        .sheet(isPresented: $showStudyMode) { FlashcardStudyView(cards: note.flashcards).padSheet() }
        .sheet(isPresented: $showExamMode) { ExamQuizView(cards: note.flashcards).padSheet() }
        .sheet(isPresented: $showRecorder) { LectureRecorderView(note: note).macSheetSize(height: 640) }
        .sheet(item: $previewPhoto) { photo in
            NavigationStack {
                ZStack {
                    AppBackground()
                    NotePhotoView(data: photo.imageData)
                        .scaledToFit()
                        .padding()
                }
                .navigationTitle("Фото")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { previewPhoto = nil }
                    }
                }
            }
            .macSheetSize()
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                attachImageData(data)
            }
            .ignoresSafeArea()
        }
        #endif
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: LectureImport.allowedTypes,
                      allowsMultipleSelection: true) { result in
            Task { await importFiles(result) }
        }
        #if canImport(PhotosUI)
        .photosPicker(isPresented: $showAttachPhotos, selection: $notePhotos, maxSelectionCount: 8, matching: .images)
        #endif
        .alert("Не получилось", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Понятно") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            var hydrated = false
            for item in note.recordings {
                if item.audioData.isEmpty {
                    LectureAudioStore.hydrateIfNeeded(item, noteID: note.id)
                    if !item.audioData.isEmpty { hydrated = true }
                }
            }
            if hydrated { save() }
        }
        .onDisappear {
            player.stop()
            save()
        }
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

                Button { showRecorder = true } label: {
                    Label("Лекция", systemImage: "mic.fill")
                }
                .buttonStyle(SoftButtonStyle())

                Button { showImporter = true } label: {
                    Label("PDF / слайды", systemImage: "doc.badge.plus")
                }
                .buttonStyle(SoftButtonStyle())

                #if canImport(PhotosUI)
                PhotosPicker(selection: $slidePhotos, maxSelectionCount: 12, matching: .images) {
                    Label("Фото слайдов", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(SoftButtonStyle())
                .onChange(of: slidePhotos) { _, items in
                    guard !items.isEmpty else { return }
                    Task { await importPhotos(items) }
                }

                PhotosPicker(selection: $notePhotos, maxSelectionCount: 8, matching: .images) {
                    Label("Фото в конспект", systemImage: "photo.badge.plus")
                }
                .buttonStyle(SoftButtonStyle())
                .onChange(of: notePhotos) { _, items in
                    guard !items.isEmpty else { return }
                    Task { await attachPhotos(items) }
                }
                #endif

                #if os(iOS)
                Button { showCamera = true } label: {
                    Label("Камера", systemImage: "camera.fill")
                }
                .buttonStyle(SoftButtonStyle())
                #endif

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
                        Label("Тест", systemImage: "list.bullet.rectangle.fill")
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

    private func processingBannerCustom(_ text: String) -> some View {
        HStack(spacing: 11) {
            ProgressView().controlSize(.small).tint(Theme.primary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(13)
        .background(Theme.chipGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private var cameraInsert: (() -> Void)? {
        #if os(iOS)
        { showCamera = true }
        #else
        nil
        #endif
    }

    private var bodyBlock: some View {
        GlassCard {
            if isEditing {
                NoteBodyEditor(
                    text: $note.body,
                    onInsertPhoto: { showAttachPhotos = true },
                    onInsertCamera: cameraInsert,
                    onInsertLecture: { showRecorder = true },
                    onInsertPDF: { showImporter = true },
                    focusedID: $focusedBlockID
                )
                .frame(minHeight: 280, alignment: .topLeading)
            } else if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Конспект пуст")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Вставьте текст лекции или нажмите «Начать писать». Заголовки, списки и фото добавляются с панели — как в Заметках.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Начать писать") {
                        withAnimation { isEditing = true }
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            } else {
                MedicalTextView(
                    text: note.body,
                    highlightTerms: settings.termHintsEnabled,
                    onTermTap: { selectedTerm = $0 },
                    onChecklistToggle: { line in
                        note.body = NoteMarkup.toggleChecklist(in: note.body, lineIndex: line)
                        save()
                    }
                )
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
        if note.groupID != nil {
            Task { await GroupCloud.publishNote(note) }
        }
    }

    private func deleteNote() {
        context.delete(note)
        try? context.save()
        dismiss()
    }

    private var sourcesCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if !note.sourceFileName.isEmpty {
                    Label(note.sourceFileName, systemImage: "doc.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                if !note.recordings.isEmpty {
                    Button { showRecorder = true } label: {
                        Label("\(pluralRu(note.recordings.count, "голосовая запись", "голосовые записи", "голосовых записей"))",
                              systemImage: "mic.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                    }
                    .buttonStyle(.plain)

                    ForEach(note.recordings.sorted { $0.createdAt > $1.createdAt }) { item in
                        if !item.segments.isEmpty || !item.transcript.isEmpty {
                            TranscriptTimeline(recording: item, noteID: note.id, player: player)
                        }
                    }
                }
            }
        }
    }

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Фото",
                          subtitle: note.photos.isEmpty
                            ? "Слайд, доска или схема"
                            : pluralRu(note.photos.count, "снимок", "снимка", "снимков"))

            if note.photos.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Слайд, доска или схема — добавьте снимок рядом с текстом.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 8) {
                        #if canImport(PhotosUI)
                        Button {
                            showAttachPhotos = true
                        } label: {
                            Label("Фото", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(SoftButtonStyle())
                        #endif
                        #if os(iOS)
                        Button {
                            showCamera = true
                        } label: {
                            Label("Камера", systemImage: "camera.fill")
                        }
                        .buttonStyle(SoftButtonStyle())
                        #endif
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(note.photos.sorted { $0.createdAt > $1.createdAt }) { photo in
                        Button {
                            previewPhoto = photo
                        } label: {
                            NotePhotoView(data: photo.imageData)
                                .frame(height: 104)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                context.delete(photo)
                                save()
                            } label: {
                                Label("Удалить фото", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            isImporting = true
            defer { isImporting = false }
            do {
                let imported = try await LectureImport.load(urls: urls)
                applyImport(imported)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    #if canImport(PhotosUI)
    private func attachPhotos(_ items: [PhotosPickerItem]) async {
        defer { notePhotos = [] }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            attachImageData(data)
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        isImporting = true
        defer {
            isImporting = false
            slidePhotos = []
        }
        var images: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                images.append(data)
            }
        }
        do {
            let imported = try await LectureImport.load(images: images)
            applyImport(imported)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    private func attachImageData(_ data: Data) {
        let jpeg = NoteImageCodec.preparedJPEG(from: data)
        guard !jpeg.isEmpty else { return }
        note.photos.append(NotePhoto(imageData: jpeg))
        save()
    }

    private func applyImport(_ imported: ImportedLecture) {
        if note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            note.title = imported.title
        }
        if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            note.body = imported.text
        } else {
            note.body += "\n\n" + imported.text
        }
        note.sourceFileName = imported.sourceName
        note.updatedAt = Date()
        try? context.save()
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
