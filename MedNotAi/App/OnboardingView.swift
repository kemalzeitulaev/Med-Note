import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @State private var page = 0

    private struct Slide: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let text: String
        let colors: [Color]
    }

    private let slides: [Slide] = [
        .init(icon: "brain.head.profile",
              title: "Ассистент на базе ИИ",
              text: "Мгновенные ответы на вопросы, объяснения сложных терминов и концепций — прямо во время подготовки.",
              colors: [Color(hex: 0x7C3AED), Color(hex: 0xA855F7)]),
        .init(icon: "wand.and.stars",
              title: "Конспекты, которые собираются сами",
              text: "ИИ структурирует материал лекции, делает выжимку и превращает её во флеш-карты за несколько секунд.",
              colors: [Color(hex: 0xA855F7), Color(hex: 0xEC4899)]),
        .init(icon: "person.2.fill",
              title: "Групповое конспектирование",
              text: "Совместная работа над материалами: общая база знаний курса вместо разрозненных тетрадей.",
              colors: [Color(hex: 0xEC4899), Color(hex: 0xF59E0B)]),
        .init(icon: "calendar.badge.clock",
              title: "Учёба по расписанию",
              text: "Лекции, практика, дедлайны и экзамены в одном календаре с напоминаниями.",
              colors: [Color(hex: 0x0EA5E9), Color(hex: 0x7C3AED)])
    ]

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                if page < slides.count {
                    slideStack
                } else {
                    ProfileSetupStep(onFinish: finish)
                }
            }
            // На iPad и Mac онбординг остаётся узкой центральной колонкой.
            .readableWidth(520)
        }
    }

    private var slideStack: some View {
        let slide = slides[max(0, min(page, slides.count - 1))]

        return VStack(spacing: 24) {
            HStack {
                Spacer()
                Button("Пропустить") { withAnimation { page = slides.count } }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Spacer()

            VStack(spacing: 22) {
                GradientIcon(systemName: slide.icon, size: 120, colors: slide.colors)
                Text(slide.title)
                    .font(.title.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(slide.text)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }
            .id(slide.id)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            Spacer()

            HStack(spacing: 7) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, _ in
                    Capsule()
                        .fill(index == page ? Theme.primary : Theme.hairline)
                        .frame(width: index == page ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(duration: 0.3), value: page)

            Button(page == slides.count - 1 ? "Начать" : "Далее") {
                withAnimation(.spring(duration: 0.35)) { page += 1 }
            }
            .buttonStyle(BrandButtonStyle())
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 25)
                .onEnded { value in
                    withAnimation(.spring(duration: 0.35)) {
                        if value.translation.width < -40 {
                            page = min(page + 1, slides.count)
                        } else if value.translation.width > 40 {
                            page = max(page - 1, 0)
                        }
                    }
                }
        )
    }

    private func finish() {
        withAnimation { settings.hasSeenOnboarding = true }
    }
}

// MARK: - Шаг с профилем

private struct ProfileSetupStep: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    let onFinish: () -> Void

    @State private var name = ""
    @State private var university = ""
    @State private var course = 3
    @State private var language: AppLanguage = .ru
    @State private var loadSamples = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    GradientIcon(systemName: "person.text.rectangle.fill", size: 64)
                    Text("Пара слов о вас")
                        .font(.title.bold())
                        .foregroundStyle(Theme.textPrimary)
                    Text("Это поможет ассистенту подстроиться под ваш курс и язык обучения.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 40)

                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        LabeledField(title: "Имя", placeholder: "Как к вам обращаться", text: $name)
                        Divider().overlay(Theme.hairline)
                        LabeledField(title: "Университет", placeholder: "Например, КГМУ", text: $university)
                        Divider().overlay(Theme.hairline)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Курс").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                            Picker("Курс", selection: $course) {
                                ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }

                GlassCard {
                    Toggle(isOn: $loadSamples) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Загрузить примеры")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Четыре демонстрационных конспекта, расписание и диалог с ассистентом. Без этого приложение откроется пустым.")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Theme.primary)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Язык обучения")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                        ForEach(AppLanguage.allCases) { lang in
                            Button {
                                language = lang
                            } label: {
                                HStack {
                                    Text(lang.flag)
                                    Text(lang.title).foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    if language == lang {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Theme.primary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button("Готово") {
                    settings.userName = name.trimmingCharacters(in: .whitespaces)
                    settings.university = university.trimmingCharacters(in: .whitespaces)
                    settings.course = course
                    settings.language = language
                    if loadSamples { SampleData.seed(context) }
                    onFinish()
                }
                .buttonStyle(BrandButtonStyle())

                Text("Все функции открыты бесплатно — подписка не нужна.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 30)
            }
            .padding(.horizontal, 22)
        }
        .onAppear {
            // Подхватываем уже известное: имя приходит из Apple или Google,
            // язык мог быть выбран до перезапуска онбординга.
            if name.isEmpty { name = settings.userName }
            if university.isEmpty { university = settings.university }
            language = settings.language
        }
    }
}

struct LabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
        }
    }
}

#Preview {
    OnboardingView()
        .environment(AppSettings.shared)
}
