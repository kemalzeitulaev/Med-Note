import SwiftUI
import SwiftData

struct ProfileView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AIAssistant.self) private var assistant
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var context
    @Environment(\.isCloudSyncEnabled) private var isCloudSyncEnabled

    @Query private var notes: [Note]
    @Query private var events: [StudyEvent]

    @State private var auth = AuthService.shared

    @State private var showAISettings = false
    @State private var showGlossary = false
    @State private var showSignIn = false
    @State private var showSignOutConfirmation = false
    @State private var showDeleteAccountConfirmation = false
    @State private var showEraseConfirmation = false

    var body: some View {
        @Bindable var settings = settings

        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 15) {
                    profileCard
                    accountCard
                    syncCard
                    statsCard
                    preferencesCard
                    remindersCard
                    toolsCard
                    dataCard
                    aboutCard
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, 18)
                .readableWidth(620)
            }
        }
        .navigationTitle("Профиль")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showAISettings) { AISettingsView().macSheetSize(height: 520) }
        .sheet(isPresented: $showGlossary) { GlossaryView().macSheetSize(width: 720, height: 640) }
        .sheet(isPresented: $showSignIn) {
            NavigationStack { SignInView() }.macSheetSize(height: 620)
        }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $showSignOutConfirmation, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { auth.signOut() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Вы вернётесь на экран входа. Конспекты останутся на устройстве, аккаунт из базы не удаляется.")
        }
        .confirmationDialog("Удалить аккаунт?", isPresented: $showDeleteAccountConfirmation, titleVisibility: .visible) {
            Button("Удалить аккаунт", role: .destructive) {
                Task { await auth.deleteEmailAccount() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Почта и хеш пароля будут стёрты из зашифрованной базы на этом устройстве. Конспекты останутся.")
        }
        .confirmationDialog("Удалить все данные?", isPresented: $showEraseConfirmation, titleVisibility: .visible) {
            Button("Удалить всё", role: .destructive) { eraseEverything() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Конспекты, карточки, диалоги, группы и расписание будут удалены безвозвратно.")
        }
    }

    // MARK: - Аккаунт

    private var accountCard: some View {
        GlassCard {
            if let profile = auth.profile {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: accountIcon(profile.provider))
                            .font(.title2)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.provider == .email
                                 ? "Почта · доступен на iPhone, iPad и Mac"
                                 : "Вход через \(profile.provider.title)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(profile.email ?? "Почта скрыта провайдером")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Theme.success)
                    }
                    Divider().overlay(Theme.hairline)
                    Button("Выйти из аккаунта") { showSignOutConfirmation = true }
                        .font(.subheadline)
                        .foregroundStyle(Theme.danger)
                    if profile.provider == .email {
                        Button("Удалить аккаунт с устройства") { showDeleteAccountConfirmation = true }
                            .font(.subheadline)
                            .foregroundStyle(Theme.danger)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    settingLabel("person.badge.shield.checkmark.fill", "Вход не выполнен",
                                 "Войдите по почте, чтобы привязать профиль к аккаунту на этом устройстве")
                    Button("Войти") { showSignIn = true }
                        .buttonStyle(SoftButtonStyle(expands: true))
                }
            }
        }
    }

    private var syncCard: some View {
        GlassCard {
            HStack(spacing: 12) {
                GradientIcon(systemName: "icloud", size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCloudSyncEnabled ? "iCloud включён" : "Только это устройство")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(isCloudSyncEnabled
                         ? "Конспекты, фото, карточки, календарь, диалоги, голосовые лекции и группы синхронизируются через iCloud."
                         : "Личная команда разработчика не даёт iCloud. Конспекты пока только на этом устройстве. После платной подписки Apple Developer синк включится сам.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Настройки

    private var preferencesCard: some View {
        @Bindable var settings = settings

        return GlassCard {
            VStack(spacing: 0) {
                Toggle(isOn: $settings.termHintsEnabled) {
                    settingLabel("character.book.closed.fill", "Подсказки по терминам",
                                 "Подсвечивать медицинские термины в тексте")
                }
                .tint(Theme.primary)

                Divider().overlay(Theme.hairline).padding(.vertical, 12)

                Picker(selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text("\(lang.flag)  \(lang.title)").tag(lang)
                    }
                } label: {
                    settingLabel("globe", "Язык", "Язык интерфейса и ответов ассистента")
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var remindersCard: some View {
        @Bindable var settings = settings

        return GlassCard {
            VStack(spacing: 0) {
                Toggle(isOn: $settings.remindersEnabled) {
                    settingLabel("bell.badge.fill", "Напоминания",
                                 "Уведомления о занятиях, экзаменах и дедлайнах")
                }
                .tint(Theme.primary)
                .onChange(of: settings.remindersEnabled) { _, isOn in
                    // Разрешение запрашиваем в момент включения, а не при запуске:
                    // системный запрос без контекста почти всегда отклоняют.
                    guard isOn else { return }
                    Task { await StudyReminders.shared.requestPermission() }
                }

                if settings.remindersEnabled {
                    Divider().overlay(Theme.hairline).padding(.vertical, 12)

                    Picker(selection: $settings.reminderLeadMinutes) {
                        ForEach([10, 15, 30, 60, 120], id: \.self) { minutes in
                            Text(minutes < 60 ? "\(minutes) мин" : "\(minutes / 60) ч").tag(minutes)
                        }
                    } label: {
                        settingLabel("clock.fill", "Напомнить заранее",
                                     "За сколько предупреждать о начале")
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var toolsCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                navRow("sparkles", "Настройки ИИ",
                       assistant.isDemoMode ? "Демо-режим" : settings.model) { showAISettings = true }
                Divider().overlay(Theme.hairline).padding(.vertical, 12)
                navRow("character.book.closed.fill", "Глоссарий",
                       pluralRu(MedicalGlossary.terms.count, "термин", "термина", "терминов")) { showGlossary = true }
            }
        }
    }

    // MARK: - Данные

    private var dataCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                if notes.isEmpty {
                    Button {
                        SampleData.seed(context)
                    } label: {
                        HStack {
                            settingLabel("sparkles.rectangle.stack", "Загрузить примеры",
                                         "Демонстрационные конспекты, расписание и диалог")
                            Spacer()
                            Image(systemName: "arrow.down.circle")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        showEraseConfirmation = true
                    } label: {
                        HStack {
                            settingLabel("trash.fill", "Удалить все данные",
                                         "Очистить конспекты, карточки, диалоги и расписание")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.danger)
                }
            }
        }
    }

    private func eraseEverything() {
        for note in notes { context.delete(note) }
        for event in events { context.delete(event) }
        for thread in (try? context.fetch(FetchDescriptor<ChatThread>())) ?? [] { context.delete(thread) }
        for group in (try? context.fetch(FetchDescriptor<StudyGroup>())) ?? [] { context.delete(group) }
        try? context.save()
        settings.hasSeededSamples = false
    }

    // MARK: - Карточки

    private var profileCard: some View {
        @Bindable var settings = settings

        return GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Circle()
                        .fill(Theme.brandGradient)
                        .frame(width: 62, height: 62)
                        .overlay {
                            Text(String(settings.greetingName.prefix(1)).uppercased())
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(settings.greetingName.capitalizedFirst)
                            .font(.title3.bold())
                            .foregroundStyle(Theme.textPrimary)
                        Text(subtitleText)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }

                Divider().overlay(Theme.hairline)

                LabeledField(title: "Имя", placeholder: "Ваше имя", text: $settings.userName)
                LabeledField(title: "Университет", placeholder: "Название вуза", text: $settings.university)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Курс")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Picker("Курс", selection: $settings.course) {
                        ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var subtitleText: String {
        var parts: [String] = []
        if !settings.university.isEmpty { parts.append(settings.university) }
        parts.append("\(settings.course) курс")
        return parts.joined(separator: " · ")
    }

    private var statsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Статистика")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 10) {
                    StatPill(value: "\(notes.count)", caption: "конспектов", icon: "doc.text.fill", color: Theme.primary)
                    StatPill(value: "\(notes.reduce(0) { $0 + $1.flashcards.count })", caption: "карточек", icon: "rectangle.on.rectangle.angled", color: Theme.accentPink)
                    StatPill(value: "\(events.filter(\.isDone).count)", caption: "выполнено", icon: "checkmark.circle.fill", color: Theme.success)
                }
            }
        }
    }

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("MedNoteAi")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Интеллектуальный ассистент для студентов-медиков: конспекты, ИИ-разбор материала, групповая работа и календарь учёбы. Данные синхронизируются через iCloud.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text("Версия 1.0 · Учебный материал, не является клинической рекомендацией.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
        }
    }

    private func accountIcon(_ provider: AuthProvider) -> String {
        switch provider {
        case .apple: "apple.logo"
        case .google: "g.circle.fill"
        case .email: "envelope.fill"
        }
    }

    // MARK: - Строки настроек

    private func settingLabel(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(Theme.primary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func navRow(_ icon: String, _ title: String, _ value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                settingLabel(icon, title, value)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Настройки ИИ

struct AISettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 11) {
                        Image(systemName: settings.isLiveAIConfigured ? "checkmark.seal.fill" : "sparkles")
                            .foregroundStyle(settings.isLiveAIConfigured ? Theme.success : Theme.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.isLiveAIConfigured ? "Подключена своя модель" : "Демо-режим")
                                .font(.subheadline.weight(.semibold))
                            Text(settings.isLiveAIConfigured
                                 ? "Запросы идут на \(settings.normalizedBaseURL)"
                                 : "Ответы формируются офлайн из встроенной базы знаний")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                Section {
                    TextField("Базовый URL", text: $settings.apiBaseURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Модель", text: $settings.model)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("API-ключ", text: $settings.apiKey)
                } header: {
                    Text("Провайдер")
                } footer: {
                    Text("Поддерживается любой OpenAI-совместимый эндпоинт: OpenAI, OpenRouter, Together, локальный сервер. Ключ хранится только на устройстве.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Проверить подключение")
                            Spacer()
                            if isTesting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(isTesting)

                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("OK") ? Theme.success : Theme.danger)
                    }
                }

                if settings.isLiveAIConfigured {
                    Section {
                        Button("Отключить и вернуться в демо-режим", role: .destructive) {
                            settings.apiKey = ""
                            testResult = nil
                        }
                    }
                }
            }
            .navigationTitle("Настройки ИИ")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let reply = try await AIAssistant.shared.explain(term: "гомеостаз")
            testResult = "OK · ответ получен, \(pluralRu(reply.count, "символ", "символа", "символов"))"
        } catch {
            testResult = error.localizedDescription
        }
    }
}
