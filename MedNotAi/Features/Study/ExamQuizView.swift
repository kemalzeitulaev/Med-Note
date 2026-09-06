import SwiftUI
import SwiftData

/// Экзамен по карточкам: сначала свой ответ, потом сверка.
///
/// Это не повторение по Лейтнеру — интервалы не трогаем, чтобы можно было
/// проверить себя перед коллоквиумом, не сдвигая расписание заучивания.
struct ExamQuizView: View {
    let cards: [Flashcard]

    @Environment(\.dismiss) private var dismiss

    @State private var queue: [Flashcard] = []
    @State private var index = 0
    @State private var draft = ""
    @State private var revealed = false
    @State private var correct = 0
    @FocusState private var answerFocused: Bool

    private var current: Flashcard? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                if queue.isEmpty {
                    EmptyStateView(icon: "checkmark.seal",
                                   title: "Карточек нет",
                                   message: "Сгенерируйте флеш-карты из конспекта и вернитесь к экзамену.")
                } else if let card = current {
                    question(card)
                } else {
                    resultView
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
        }
        .onAppear {
            if queue.isEmpty { queue = cards.shuffled() }
        }
    }

    private func question(_ card: Flashcard) -> some View {
        VStack(spacing: 16) {
            BrandProgressBar(value: queue.isEmpty ? 0 : Double(index) / Double(queue.count))
                .padding(.horizontal, 22)

            Text("Вопрос \(index + 1) из \(queue.count)")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            GlassCard(padding: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ВОПРОС")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.primary)
                    Text(card.question)
                        .font(.title3)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)

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
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)

                HStack(spacing: 12) {
                    Button {
                        advance(wasCorrect: false)
                    } label: {
                        Label("Ошибся", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SoftButtonStyle(expands: true))

                    Button {
                        advance(wasCorrect: true)
                    } label: {
                        Label("Верно", systemImage: "checkmark")
                    }
                    .buttonStyle(BrandButtonStyle(expands: true))
                }
                .padding(.horizontal, 20)
            } else {
                TextField("Напишите ответ своими словами", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($answerFocused)
                    .lineLimit(3...8)
                    .padding(14)
                    .background(Theme.surfaceTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 20)

                Button("Сверить с эталоном") {
                    answerFocused = false
                    withAnimation(.spring(duration: 0.3)) { revealed = true }
                }
                .buttonStyle(BrandButtonStyle())
                .padding(.horizontal, 20)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .onAppear { answerFocused = true }
    }

    private var resultView: some View {
        VStack(spacing: 18) {
            GradientIcon(systemName: scoreIcon, size: 90)
            Text(scoreTitle)
                .font(.title.bold())
                .foregroundStyle(Theme.textPrimary)
            Text("Верно: \(correct) из \(queue.count)")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
            Button("Пройти ещё раз") {
                queue.shuffle()
                index = 0
                correct = 0
                draft = ""
                revealed = false
            }
            .buttonStyle(BrandButtonStyle(expands: false))
        }
        .padding(30)
    }

    private var scoreRatio: Double {
        queue.isEmpty ? 0 : Double(correct) / Double(queue.count)
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

    private func advance(wasCorrect: Bool) {
        if wasCorrect { correct += 1 }
        withAnimation(.spring(duration: 0.3)) {
            draft = ""
            revealed = false
            index += 1
        }
    }
}
