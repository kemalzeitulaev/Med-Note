import SwiftUI
import SwiftData

struct GroupsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(AppSettings.self) private var settings
    @Environment(\.isWideLayout) private var isWide

    @Query(sort: \StudyGroup.createdAt, order: .reverse) private var groups: [StudyGroup]
    @Query private var notes: [Note]

    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showPaywall = false
    @State private var groupPendingDeletion: StudyGroup?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        intro

                        if groups.isEmpty {
                            EmptyStateView(
                                icon: "person.2.badge.plus",
                                title: "Пока нет групп",
                                message: "Создайте группу курса или присоединитесь по коду приглашения — и ведите конспекты вместе.",
                                actionTitle: "Создать группу",
                                action: { create() }
                            )
                        } else {
                            // На iPad и Mac группы ложатся в две колонки.
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14),
                                                     count: isWide ? 2 : 1), spacing: 14) {
                                ForEach(groups) { group in
                                    NavigationLink {
                                        GroupDetailView(group: group)
                                    } label: {
                                        groupCard(group)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            Clipboard.copy(group.inviteCode)
                                        } label: {
                                            Label("Скопировать код приглашения", systemImage: "doc.on.doc")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            groupPendingDeletion = group
                                        } label: {
                                            Label("Удалить", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 10)
                    }
                    .padding(.horizontal, isWide ? 24 : 18)
                    .readableWidth(isWide ? 1000 : Layout.contentMaxWidth)
                }
            }
            .navigationTitle("Группы")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Создать группу", systemImage: "plus") { create() }
                        Button("Войти по коду", systemImage: "key.fill") { join() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Создать группу или войти по коду")
                }
            }
            .sheet(isPresented: $showCreate) { GroupEditorView().macSheetSize(height: 460) }
            .sheet(isPresented: $showJoin) { JoinGroupView().macSheetSize(height: 400) }
            .sheet(isPresented: $showPaywall) { PaywallView().macSheetSize(height: 700) }
            .confirmationDialog(
                groupPendingDeletion.map { "Удалить группу «\($0.name)»?" } ?? "Удалить группу?",
                isPresented: Binding(
                    get: { groupPendingDeletion != nil },
                    set: { if !$0 { groupPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Удалить", role: .destructive) {
                    if let group = groupPendingDeletion { delete(group) }
                    groupPendingDeletion = nil
                }
                Button("Отмена", role: .cancel) { groupPendingDeletion = nil }
            } message: {
                Text("Общие конспекты останутся у вас — они просто перестанут быть групповыми.")
            }
        }
    }

    private func delete(_ group: StudyGroup) {
        // Конспекты ссылаются на группу обычным UUID, поэтому связь снимаем сами:
        // иначе они остались бы висеть с меткой несуществующей группы.
        context.detachNotes(fromGroup: group.id)
        context.delete(group)
        try? context.save()
    }

    private var intro: some View {
        GlassCard {
            HStack(spacing: 13) {
                GradientIcon(systemName: "person.2.fill", size: 46,
                             colors: [Color(hex: 0x10B981), Color(hex: 0x14B8A6)])
                VStack(alignment: .leading, spacing: 3) {
                    Text("Групповое конспектирование")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Общая база конспектов курса вместо разрозненных тетрадей.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
        }
    }

    private func groupCard(_ group: StudyGroup) -> some View {
        let groupNotes = notes.filter { $0.groupID == group.id }
        return GlassCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 11) {
                    Circle()
                        .fill(group.accentColor.opacity(0.15))
                        .frame(width: 42, height: 42)
                        .overlay {
                            Text(String(group.name.prefix(1)).uppercased())
                                .font(.headline)
                                .foregroundStyle(group.accentColor)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(group.subject)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 7) {
                    AvatarStack(names: group.memberNames, color: group.accentColor)
                    Spacer()
                    TagChip(text: pluralRu(groupNotes.count, "конспект", "конспекта", "конспектов"),
                            color: group.accentColor, icon: "doc.text.fill")
                }
            }
        }
    }

    private func create() {
        guard settings.hasFullAccess else { showPaywall = true; return }
        showCreate = true
    }

    private func join() {
        guard settings.hasFullAccess else { showPaywall = true; return }
        showJoin = true
    }
}

// MARK: - Аватары участников

struct AvatarStack: View {
    let names: [String]
    let color: Color

    var body: some View {
        HStack(spacing: -8) {
            ForEach(Array(names.prefix(4).enumerated()), id: \.offset) { _, name in
                Circle()
                    .fill(color.opacity(0.85))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Text(String(name.prefix(1)).uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
            }
            if names.count > 4 {
                Circle()
                    .fill(Theme.surfaceTint)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Text("+\(names.count - 4)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.primary)
                    }
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
            }
        }
    }
}

// MARK: - Детали группы

struct GroupDetailView: View {
    @Bindable var group: StudyGroup

    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isWideLayout) private var isWide
    @Query(sort: \Note.updatedAt, order: .reverse) private var allNotes: [Note]

    @State private var newNote: Note?
    @State private var showInvite = false

    private var groupNotes: [Note] {
        allNotes.filter { $0.groupID == group.id }
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 15) {
                    headerCard
                    membersCard

                    SectionHeader(title: "Общие конспекты",
                                  subtitle: pluralRu(groupNotes.count, "конспект", "конспекта", "конспектов"))

                    if groupNotes.isEmpty {
                        GlassCard {
                            Text("В группе ещё нет общих конспектов. Создайте первый — он появится у всех участников.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14),
                                                 count: isWide ? 2 : 1), spacing: 14) {
                            ForEach(groupNotes) { note in
                                NavigationLink { NoteEditorView(note: note) } label: {
                                    NoteRow(note: note)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button {
                        let note = Note(subject: group.subject, colorIndex: group.colorIndex, groupID: group.id)
                        context.insert(note)
                        newNote = note
                    } label: {
                        Label("Добавить общий конспект", systemImage: "plus")
                    }
                    .buttonStyle(BrandButtonStyle())

                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, isWide ? 24 : 18)
                .readableWidth(isWide ? 1000 : Layout.contentMaxWidth)
            }
        }
        .navigationTitle(group.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $newNote, onDismiss: { context.purgeBlankNotes() }) { note in
            NavigationStack { NoteEditorView(note: note, startsEditing: true) }
                .macSheetSize()
        }
        .sheet(isPresented: $showInvite) { InviteSheet(group: group).macSheetSize(height: 420) }
    }

    private var headerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    GradientIcon(systemName: "person.2.fill", size: 48,
                                 colors: [group.accentColor, group.accentColor.opacity(0.6)])
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text(group.subject)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                Button {
                    showInvite = true
                } label: {
                    Label("Пригласить · код \(group.inviteCode)", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SoftButtonStyle(expands: true))
            }
        }
    }

    private var membersCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 11) {
                Text("Участники (\(group.memberNames.count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                ForEach(Array(group.memberNames.enumerated()), id: \.offset) { idx, name in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Theme.paletteColor(idx).opacity(0.85))
                            .frame(width: 30, height: 30)
                            .overlay {
                                Text(String(name.prefix(1)).uppercased())
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if idx == 0 {
                            TagChip(text: "владелец", color: Theme.primary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Приглашение

struct InviteSheet: View {
    let group: StudyGroup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                GradientIcon(systemName: "key.fill", size: 78)
                Text("Код приглашения")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text(group.inviteCode)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .tracking(6)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(Theme.chipGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("Отправьте код однокурсникам — они смогут войти в группу «\(group.name)» и работать над конспектами вместе.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                Button {
                    Clipboard.copy(group.inviteCode)
                } label: {
                    Label("Скопировать код", systemImage: "doc.on.doc")
                }
                .buttonStyle(BrandButtonStyle())

                Spacer()
            }
            .padding(24)
            .background(AppBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Создание группы

struct GroupEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var name = ""
    @State private var subject = ""
    @State private var colorIndex = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Группа") {
                    TextField("Название, например «Кардио 3 курс»", text: $name)
                    TextField("Предмет", text: $subject)
                }
                Section("Цвет") {
                    HStack(spacing: 9) {
                        ForEach(0..<Theme.paletteColors.count, id: \.self) { idx in
                            Circle()
                                .fill(Theme.paletteColor(idx))
                                .frame(width: 26, height: 26)
                                .overlay {
                                    if colorIndex == idx {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { colorIndex = idx }
                        }
                    }
                }
            }
            .navigationTitle("Новая группа")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        let group = StudyGroup(
                            name: name,
                            subject: subject.isEmpty ? "Общее" : subject,
                            memberNames: [settings.greetingName.capitalizedFirst],
                            colorIndex: colorIndex
                        )
                        context.insert(group)
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Вход по коду

struct JoinGroupView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Query private var groups: [StudyGroup]

    @State private var code = ""
    @State private var message: String?
    @State private var joinedGroup: StudyGroup?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                GradientIcon(systemName: joinedGroup == nil ? "person.badge.key.fill" : "checkmark.circle.fill", size: 74)
                Text(joinedGroup.map { "Вы в группе «\($0.name)»" } ?? "Введите код приглашения")
                    .font(.title3.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                TextField("XXXXXX", text: $code)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .autocorrectionDisabled()
                    .padding(.vertical, 16)
                    .background(Theme.surfaceTint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                }

                if joinedGroup == nil {
                    Button("Войти в группу", action: join)
                        .buttonStyle(BrandButtonStyle())
                        .disabled(PromoCodeService.normalize(code).count < 6)
                } else {
                    Text("Группа появилась в списке — откройте её, чтобы работать с общими конспектами.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Готово") { dismiss() }
                        .buttonStyle(BrandButtonStyle())
                }

                Spacer()
            }
            .padding(24)
            .background(AppBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(joinedGroup == nil ? "Отмена" : "Закрыть") { dismiss() }
                }
            }
        }
    }

    private func join() {
        let target = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard let group = groups.first(where: { $0.inviteCode == target }) else {
            message = "Группа с таким кодом не найдена. Проверьте код у того, кто вас пригласил."
            return
        }
        let me = settings.greetingName.capitalizedFirst
        if group.memberNames.contains(me) {
            message = "Вы уже состоите в этой группе."
        } else {
            group.memberNames.append(me)
            try? context.save()
        }
        withAnimation(.spring(duration: 0.3)) { joinedGroup = group }
    }
}
