import SwiftUI
import SwiftData

// MARK: - Список диалогов

struct ChatListView: View {
    @Environment(\.modelContext) private var context
    @Environment(AIAssistant.self) private var assistant
    @Environment(\.isWideLayout) private var isWide

    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
    @State private var openThread: ChatThread?
    /// Как и в списке конспектов, держим идентификатор: удалённый из другой
    /// колонки диалог иначе оставлял ссылку на несуществующую модель.
    @State private var selectedThreadID: UUID?
    @State private var threadPendingDeletion: ChatThread?

    private var selectedThread: ChatThread? {
        guard let selectedThreadID else { return nil }
        return threads.first { $0.id == selectedThreadID }
    }

    var body: some View {
        content
            .confirmationDialog(
                threadPendingDeletion.map { "Удалить «\($0.title)»?" } ?? "Удалить диалог?",
                isPresented: Binding(
                    get: { threadPendingDeletion != nil },
                    set: { if !$0 { threadPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Удалить", role: .destructive) {
                    if let thread = threadPendingDeletion { delete(thread) }
                    threadPendingDeletion = nil
                }
                Button("Отмена", role: .cancel) { threadPendingDeletion = nil }
            } message: {
                Text("Переписка с ассистентом будет удалена безвозвратно.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if isWide {
            NavigationSplitView {
                listColumn
                    .listColumnWidth()
            } detail: {
                if let selectedThread {
                    ChatView(thread: selectedThread)
                        .id(selectedThread.id)
                } else {
                    ZStack {
                        AppBackground()
                        EmptyStateView(icon: "sparkles",
                                       title: "Выберите диалог",
                                       message: "Или начните новый — ассистент разберёт тему, объяснит термин и поможет с подготовкой.",
                                       actionTitle: "Начать диалог",
                                       action: { newThread() })
                        .readableWidth(460)
                    }
                }
            }
        } else {
            NavigationStack {
                listColumn
                    .navigationDestination(item: $openThread) { ChatView(thread: $0) }
            }
        }
    }

    private var listColumn: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 14) {
                    heroCard

                    if !threads.isEmpty {
                        SectionHeader(title: "История диалогов")
                        ForEach(threads) { thread in
                            Group {
                                if isWide {
                                    Button { selectedThreadID = thread.id } label: {
                                        threadRow(thread, isSelected: selectedThreadID == thread.id)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink { ChatView(thread: thread) } label: {
                                        threadRow(thread)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    threadPendingDeletion = thread
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 10)
                }
                .padding(.horizontal, 18)
                .readableWidth(isWide ? Layout.listMaxWidth : Layout.contentMaxWidth)
            }
        }
        .navigationTitle("Ассистент")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { newThread() } label: {
                    Label("Новый диалог", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }

    private var heroCard: some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 13) {
                    GradientIcon(systemName: "brain.head.profile", size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Спросите что угодно")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text(assistant.isDemoMode ? "Демо-режим · без API-ключа" : "Подключена модель")
                            .font(.caption)
                            .foregroundStyle(assistant.isDemoMode ? Theme.warning : Theme.success)
                    }
                    Spacer()
                }

                Text("Разбор патогенеза, объяснение терминов, подготовка к экзамену — ассистент отвечает на вашем языке.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)

                Button {
                    newThread()
                } label: {
                    Label("Начать диалог", systemImage: "sparkles")
                }
                .buttonStyle(BrandButtonStyle())
            }
        }
    }

    private func threadRow(_ thread: ChatThread, isSelected: Bool = false) -> some View {
        GlassCard(padding: 14, isHighlighted: isSelected) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(thread.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(thread.updatedAt.localizedRelative)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(thread.lastPreview)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func newThread() {
        // Пустой диалог с прошлого раза переиспользуем, а не плодим ещё один.
        if let empty = threads.first(where: { $0.messages.isEmpty }) {
            if isWide { selectedThreadID = empty.id } else { openThread = empty }
            return
        }
        let thread = ChatThread()
        context.insert(thread)
        if isWide {
            selectedThreadID = thread.id
        } else {
            openThread = thread
        }
    }

    private func delete(_ thread: ChatThread) {
        if selectedThreadID == thread.id { selectedThreadID = nil }
        context.delete(thread)
        try? context.save()
    }
}

// MARK: - Диалог

struct ChatView: View {
    @Bindable var thread: ChatThread

    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(AIAssistant.self) private var assistant
    @Environment(AppSettings.self) private var settings

    @State private var draft = ""
    @State private var isSending = false
    @State private var selectedTerm: MedicalTerm?
    @State private var sendTask: Task<Void, Never>?
    /// Конспекты, на которые опирался последний ответ.
    @State private var lastSources: [KnowledgeSnippet] = []
    /// Отвечать с опорой на конспекты пользователя, а не «вообще».
    @AppStorage("chatUsesNotes") private var usesNotes = true
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "Объясни патогенез сердечной недостаточности",
        "Чем отличается некроз от апоптоза?",
        "Составь план подготовки к экзамену по фармакологии",
        "Разбери ЭКГ-признаки инфаркта миокарда"
    ]

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if thread.messages.isEmpty { emptyState }

                            ForEach(thread.sortedMessages) { message in
                                MessageBubble(message: message) { selectedTerm = $0 }
                                    .id(message.id)
                            }

                            if !lastSources.isEmpty && !isSending { sourcesCard }

                            if isSending {
                                HStack(spacing: 9) {
                                    GradientIcon(systemName: "sparkles", size: 28)
                                    TypingIndicator()
                                        .padding(.horizontal, 14).padding(.vertical, 12)
                                        .background(Theme.cardFill(scheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                                .id("typing")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .readableWidth()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: thread.messages.count) { scrollToBottom(proxy) }
                    .onChange(of: isSending) { scrollToBottom(proxy) }
                }

                inputBar
            }
        }
        .navigationTitle(thread.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $usesNotes) {
                    Label("Опираться на конспекты", systemImage: "doc.text.magnifyingglass")
                }
                .toggleStyle(.button)
                .help("Ассистент будет искать ответ в ваших конспектах")
            }
        }
        .sheet(item: $selectedTerm) { TermSheet(term: $0) }
        // Уходя с экрана, обрываем запрос: иначе ответ придёт в диалог,
        // который пользователь уже закрыл, и потратит лимит впустую.
        .onDisappear { sendTask?.cancel() }
    }

    /// Показывает, из каких конспектов взят контекст. Без этого непонятно,
    /// откуда ассистент взял цифры, и проверить ответ невозможно.
    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Учтены ваши конспекты", systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            ForEach(lastSources) { source in
                Text("• \(source.source)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyStateView(icon: "sparkles",
                           title: "О чём поговорим?",
                           message: "Задайте вопрос или выберите готовую подсказку ниже.")

            ForEach(suggestions, id: \.self) { text in
                Button {
                    draft = text
                    send()
                } label: {
                    HStack {
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(Theme.primary)
                    }
                    .padding(13)
                    .background(Theme.cardFill(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Спросите ассистента…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(Theme.cardFill(scheme), in: Capsule())
                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))

                Button {
                    if isSending { sendTask?.cancel() } else { send() }
                } label: {
                    Image(systemName: isSending ? "stop.fill" : "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Theme.brandGradient, in: Circle())
                        .shadow(color: Theme.primary.opacity(0.35), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(!isSending && draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(!isSending && draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
                .accessibilityLabel(isSending ? "Остановить ответ" : "Отправить сообщение")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .readableWidth()
            .background(.regularMaterial)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if isSending {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = thread.sortedMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @MainActor
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        let history = thread.sortedMessages
        thread.messages.append(ChatMessage(role: .user, text: text))
        if thread.title == "Новый диалог" {
            thread.title = title(from: text)
        }
        thread.updatedAt = Date()
        draft = ""
        isSending = true

        // Ищем подходящие фрагменты до запроса, чтобы модель отвечала
        // по материалу курса, а не общими формулировками из интернета.
        let knowledge = usesNotes ? KnowledgeBase.snippets(for: text, in: context) : []
        lastSources = []
        try? context.save()

        sendTask = Task {
            defer {
                isSending = false
                sendTask = nil
            }
            do {
                let reply = try await assistant.chat(history: history, newMessage: text, knowledge: knowledge)
                guard !Task.isCancelled else { return }
                thread.messages.append(ChatMessage(role: .assistant, text: reply))
                lastSources = knowledge
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                thread.messages.append(ChatMessage(role: .assistant, text: error.localizedDescription, isError: true))
            }
            thread.updatedAt = Date()
            try? context.save()
        }
    }

    /// Заголовок диалога из первого вопроса: обрезаем по границе слова,
    /// иначе в списке висят обрубки вроде «Чем отличается некро».
    private func title(from text: String) -> String {
        let limit = 42
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        guard let space = head.lastIndex(of: " ") else { return String(head) + "…" }
        return String(head[head.startIndex..<space]) + "…"
    }
}

// MARK: - Пузырь сообщения

struct MessageBubble: View {
    let message: ChatMessage
    var onTermTap: (MedicalTerm) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @State private var didCopy = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 50)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            HStack(alignment: .top, spacing: 9) {
                GradientIcon(systemName: message.isError ? "exclamationmark.triangle.fill" : "sparkles", size: 28,
                             colors: message.isError
                                ? [Theme.danger, Theme.warning]
                                : [Color(hex: 0xA855F7), Color(hex: 0xEC4899)])

                VStack(alignment: .leading, spacing: 8) {
                    MedicalTextView(text: message.text, highlightTerms: settings.termHintsEnabled, onTermTap: onTermTap)

                    HStack(spacing: 14) {
                        Button {
                            Clipboard.copy(message.text)
                            didCopy = true
                        } label: {
                            Label(didCopy ? "Скопировано" : "Копировать",
                                  systemImage: didCopy ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(didCopy ? Theme.success : Theme.textSecondary)
                        .animation(.easeOut(duration: 0.2), value: didCopy)
                        .task(id: didCopy) {
                            guard didCopy else { return }
                            try? await Task.sleep(for: .seconds(2))
                            didCopy = false
                        }
                    }
                }
                .padding(14)
                .background(Theme.cardFill(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline, lineWidth: 1))

                Spacer(minLength: 20)
            }
        }
    }
}
