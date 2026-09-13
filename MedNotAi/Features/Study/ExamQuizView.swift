import SwiftUI
import SwiftData

/// Экзамен: тест с вариантами и разбором ошибки или письменная сверка.
///
/// Интервалы Лейтнера не трогаем — это проверка перед коллоквиумом, не заучивание.
struct ExamQuizView: View {
    let cards: [Flashcard]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var mode: ExamMode = .choice
    @State private var queue: [Flashcard] = []
    @State private var questions: [ChoiceQuestion] = []
    @State private var index = 0
    @State private var draft = ""
    @State private var revealed = false
    @State private var selectedOption: Int?
    @State private var correct = 0
    @State private var contentWidth: CGFloat = 0
    @FocusState private var answerFocused: Bool

    private enum ExamMode: String, CaseIterable, Identifiable {
        case choice, written
        var id: String { rawValue }
        var title: String {
            switch self {
            case .choice: "Варианты"
            case .written: "Письменно"
            }
        }
    }

    private var currentCard: Flashcard? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    private var currentQuestion: ChoiceQuestion? {
        questions.indices.contains(index) ? questions[index] : nil
    }

    private var total: Int {
        mode == .choice ? questions.count : queue.count
    }

    /// Две колонки, когда шит уже широкий — иначе вопрос и ответы сплющиваются.
    private var useSplit: Bool {
        contentWidth >= 640 || (sizeClass == .regular && contentWidth >= 560)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                if cards.isEmpty {
                    EmptyStateView(icon: "checkmark.seal",
                                   title: "Карточек нет",
                                   message: "Сгенерируйте флеш-карты из конспекта и вернитесь к экзамену.")
                } else {
                    examBody
                }
            }
            .navigationTitle("Экзамен")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: ExamWidthKey.self, value: geo.size.width)
                }
            }
            .onPreferenceChange(ExamWidthKey.self) { contentWidth = $0 }
        }
        .onAppear { restart() }
    }

    private var examBody: some View {
        VStack(spacing: 12) {
            Picker("Режим", selection: $mode) {
                ForEach(ExamMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 22)
            .onChange(of: mode) { _, _ in restart() }

            if mode == .choice {
                if questions.isEmpty {
                    EmptyStateView(icon: "list.bullet.rectangle",
                                   title: "Не из чего собрать тест",
                                   message: "Нужны карточки с вопросом и ответом.")
                } else if let question = currentQuestion {
                    choiceQuestion(question)
                } else {
                    resultView
                }
            } else if let card = currentCard {
                writtenQuestion(card)
            } else if queue.isEmpty {
                EmptyStateView(icon: "checkmark.seal",
                               title: "Карточек нет",
                               message: "Сгенерируйте флеш-карты из конспекта.")
            } else {
                resultView
            }
        }
    }

    private func choiceQuestion(_ question: ChoiceQuestion) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    if useSplit {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(alignment: .leading, spacing: 16) {
                                progressHeader
                                questionCard(question.prompt)
                                if selectedOption != nil {
                                    explanationCard(question)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            optionsStack(question)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 16) {
                            progressHeader
                            questionCard(question.prompt)
                            optionsStack(question)
                            if selectedOption != nil {
                                explanationCard(question)
                            }
                        }
                    }
                }
                .padding(.horizontal, useSplit ? 28 : 20)
                .padding(.top, 8)
                .padding(.bottom, selectedOption == nil ? 24 : 8)
            }
            .scrollBounceBehavior(.basedOnSize)

            if selectedOption != nil {
                Button("Дальше") { advanceChoice() }
                    .buttonStyle(BrandButtonStyle())
                    .padding(.horizontal, useSplit ? 28 : 20)
                    .padding(.vertical, 12)
                    .background(Theme.surfaceTint.opacity(0.94))
            }
        }
    }

    private var progressHeader: some View {
        VStack(spacing: 8) {
            BrandProgressBar(value: total == 0 ? 0 : Double(index) / Double(total))
            Text("Вопрос \(index + 1) из \(total)")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func questionCard(_ prompt: String) -> some View {
        GlassCard(padding: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("ВОПРОС")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.primary)
                Text(prompt)
                    .font(.title3)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func optionsStack(_ question: ChoiceQuestion) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { idx, option in
                Button {
                    guard selectedOption == nil else { return }
                    selectedOption = idx
                    if idx == question.correctIndex { correct += 1 }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(choiceLetter(idx))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(optionLabelColor(idx, question: question))
                            .frame(width: 22)
                        Text(option)
                            .font(.body)
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(optionFill(idx, question: question), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(optionStroke(idx, question: question), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(selectedOption != nil)
            }
        }
    }

    private func explanationCard(_ question: ChoiceQuestion) -> some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedOption == question.correctIndex ? "ВЕРНО" : "РАЗБОР ОШИБКИ")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selectedOption == question.correctIndex ? Theme.success : Theme.danger)
                Text(question.explanation)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func writtenQuestion(_ card: Flashcard) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                BrandProgressBar(value: queue.isEmpty ? 0 : Double(index) / Double(queue.count))
                Text("Вопрос \(index + 1) из \(queue.count)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                questionCard(card.question)

                if revealed {
                    GlassCard(padding: 22) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("ЭТАЛОН")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.accentPink)
                            Text(card.answer)
                                .font(.body)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Divider().overlay(Theme.hairline)
                                Text("Ваш ответ")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(draft)
                                    .font(.body)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 12) {
                        Button {
                            advanceWritten(wasCorrect: false)
                        } label: {
                            Label("Ошибся", systemImage: "xmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SoftButtonStyle(expands: true))

                        Button {
                            advanceWritten(wasCorrect: true)
                        } label: {
                            Label("Верно", systemImage: "checkmark")
                        }
                        .buttonStyle(BrandButtonStyle(expands: true))
                    }
                } else {
                    TextField("Напишите ответ своими словами", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($answerFocused)
                        .lineLimit(3...8)
                        .padding(14)
                        .background(Theme.surfaceTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button("Сверить с эталоном") {
                        answerFocused = false
                        withAnimation(.spring(duration: 0.3)) { revealed = true }
                    }
                    .buttonStyle(BrandButtonStyle())
                }
            }
            .padding(.horizontal, useSplit ? 28 : 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: useSplit ? 720 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { answerFocused = true }
    }

    private var resultView: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            GradientIcon(systemName: scoreIcon, size: 90)
            Text(scoreTitle)
                .font(.title.bold())
                .foregroundStyle(Theme.textPrimary)
            Text("Верно: \(correct) из \(total)")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
            Button("Пройти ещё раз") { restart() }
                .buttonStyle(BrandButtonStyle(expands: false))
            Spacer(minLength: 20)
        }
        .padding(30)
    }

    private var scoreRatio: Double {
        total == 0 ? 0 : Double(correct) / Double(total)
    }

    private var scoreTitle: String {
        switch scoreRatio {
        case 0.85...: return "Отличный результат"
        case 0.6..<0.85: return "Хорошая база"
        default: return "Есть что повторить"
        }
    }

    private var scoreIcon: String {
        scoreRatio >= 0.6 ? "checkmark.seal.fill" : "book.fill"
    }

    private func restart() {
        queue = cards.shuffled()
        questions = QuizBuilder.fromCards(cards)
        index = 0
        correct = 0
        draft = ""
        revealed = false
        selectedOption = nil
    }

    private func advanceChoice() {
        withAnimation(.spring(duration: 0.3)) {
            selectedOption = nil
            index += 1
        }
    }

    private func advanceWritten(wasCorrect: Bool) {
        if wasCorrect { correct += 1 }
        withAnimation(.spring(duration: 0.3)) {
            draft = ""
            revealed = false
            index += 1
        }
    }

    private func choiceLetter(_ idx: Int) -> String {
        let letters = ["A", "B", "C", "D", "E"]
        return idx < letters.count ? letters[idx] : "\(idx + 1)"
    }

    private func optionFill(_ idx: Int, question: ChoiceQuestion) -> Color {
        guard let selectedOption else { return Theme.surfaceTint }
        if idx == question.correctIndex { return Theme.success.opacity(0.14) }
        if idx == selectedOption { return Theme.danger.opacity(0.12) }
        return Theme.surfaceTint
    }

    private func optionStroke(_ idx: Int, question: ChoiceQuestion) -> Color {
        guard let selectedOption else { return Theme.hairline }
        if idx == question.correctIndex { return Theme.success.opacity(0.55) }
        if idx == selectedOption { return Theme.danger.opacity(0.55) }
        return Theme.hairline
    }

    private func optionLabelColor(_ idx: Int, question: ChoiceQuestion) -> Color {
        guard let selectedOption else { return Theme.primary }
        if idx == question.correctIndex { return Theme.success }
        if idx == selectedOption { return Theme.danger }
        return Theme.textSecondary
    }
}

private struct ExamWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ChoiceQuestion: Identifiable, Hashable {
    var id: UUID
    var prompt: String
    var options: [String]
    var correctIndex: Int
    var explanation: String
}

/// Собирает MCQ из карточек без сети: правильный ответ + чужие ответы как ловушки.
enum QuizBuilder {
    static func fromCards(_ cards: [Flashcard], limit: Int = 12) -> [ChoiceQuestion] {
        let usable = cards.filter {
            !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return [] }

        let fillers = [
            "Это относится к другой нозологии.",
            "Обратный механизм, не этот.",
            "Нормальный вариант, не патология.",
            "Признак другого заболевания."
        ]

        return usable.shuffled().prefix(limit).map { card in
            let correct = card.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            var distractors: [String] = []
            var seen: Set<String> = [correct.normalizedForCompare]
            for other in usable.shuffled() where other.id != card.id {
                let text = other.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = text.normalizedForCompare
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                distractors.append(text)
                if distractors.count == 3 { break }
            }
            var pad = 0
            while distractors.count < 3 {
                let extra = fillers[pad % fillers.count]
                if seen.insert(extra.normalizedForCompare).inserted {
                    distractors.append(extra)
                }
                pad += 1
            }

            var options = [correct] + Array(distractors.prefix(3))
            options.shuffle()
            let correctIndex = options.firstIndex(of: correct) ?? 0
            return ChoiceQuestion(
                id: UUID(),
                prompt: card.question,
                options: options,
                correctIndex: correctIndex,
                explanation: "Верно: \(card.answer)\n\nЕсли выбрали иначе — вернитесь к конспекту и повторите этот фрагмент."
            )
        }
    }
}
