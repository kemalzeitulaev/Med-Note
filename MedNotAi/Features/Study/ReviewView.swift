import SwiftUI
import SwiftData

/// Ежедневное повторение по всем конспектам сразу.
///
/// До этого карточки жили внутри своего конспекта, и чтобы повторить материал,
/// нужно было помнить, в каком конспекте что лежит. Но забывание не разбирает
/// конспекты: повторять надо то, что подошло по сроку, независимо от темы.
/// Отсюда общая очередь — как в Anki, только без ручной настройки колод.
struct ReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var notes: [Note]

    @State private var queue: [Flashcard] = []
    @State private var index = 0
    @State private var isFlipped = false
    @State private var recalled = 0
    @State private var forgotten = 0

    /// Сколько карточек показываем за один заход. Больше — и повторение
    /// превращается в марафон, который бросают на середине.
    private static let dailyLimit = 40

    private var current: Flashcard? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                if queue.isEmpty {
                    emptyState
                } else if let card = current {
                    session(card)
                } else {
                    resultView
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
        .task { buildQueue() }
    }

    // MARK: - Очередь

    private func buildQueue() {
        let all = notes.flatMap(\.flashcards)
        // Просроченные идут первыми — они ближе всего к тому, чтобы забыться,
        // затем новые. Внутри группы порядок случайный, иначе карточки
        // заучиваются по позиции в списке, а не по содержанию.
        let due = all.filter { !$0.isNew && $0.isDue }.shuffled()
        let fresh = all.filter(\.isNew).shuffled()
        queue = Array((due + fresh).prefix(Self.dailyLimit))
    }

    // MARK: - Пустая очередь

    private var emptyState: some View {
        VStack(spacing: 16) {
            GradientIcon(systemName: "checkmark.seal.fill", size: 88)
            Text(hasAnyCards ? "На сегодня всё повторено" : "Карточек пока нет")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
            Text(hasAnyCards
                 ? nextDueText
                 : "Откройте конспект и нажмите «Флеш-карты» — ассистент соберёт вопросы из текста.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Button("Закрыть") { dismiss() }
                .buttonStyle(BrandButtonStyle(expands: false))
        }
        .padding(30)
    }

    private var hasAnyCards: Bool {
        notes.contains { !$0.flashcards.isEmpty }
    }

    private var nextDueText: String {
        let upcoming = notes.flatMap(\.flashcards).filter { !$0.isNew }.map(\.dueDate).min()
        guard let upcoming else { return "Возвращайтесь завтра." }
        let days = Calendar.current.dateComponents([.day],
                                                   from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: upcoming)).day ?? 0
        return days <= 1
            ? "Следующая порция карточек будет готова завтра."
            : "Следующее повторение — через \(pluralRu(days, "день", "дня", "дней"))."
    }

    // MARK: - Сессия

    private func session(_ card: Flashcard) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                BrandProgressBar(value: Double(index) / Double(max(queue.count, 1)))
                HStack {
                    Text("\(index + 1) из \(queue.count)")
                    Spacer()
                    Text(card.isNew ? "Новая" : "Повтор \(card.streak + 1)")
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 24)

            if let title = card.note?.displayTitle {
                TagChip(text: title, color: Theme.primary, icon: "doc.text.fill")
            }

            cardFace(card)
                .padding(.horizontal, 22)

            Spacer()

            if isFlipped {
                HStack(spacing: 12) {
                    Button {
                        answer(recalled: false)
                    } label: {
                        Label("Ещё повторить", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SoftButtonStyle(expands: true))

                    Button {
                        answer(recalled: true)
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
                .keyboardShortcut(.space, modifiers: [])
            }
            Color.clear.frame(height: 8)
        }
        .padding(.top, 14)
        .readableWidth(560)
    }

    private func cardFace(_ card: Flashcard) -> some View {
        GlassCard(padding: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text(isFlipped ? "ОТВЕТ" : "ВОПРОС")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isFlipped ? Theme.accentPink : Theme.primary)
                Text(isFlipped ? card.answer : card.question)
                    .font(.title3)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.spring) { isFlipped.toggle() } }
    }

    private func answer(recalled wasRecalled: Bool) {
        guard let card = current else { return }
        card.review(recalled: wasRecalled)
        if wasRecalled { recalled += 1 } else { forgotten += 1 }
        try? context.save()
        withAnimation(.spring) {
            isFlipped = false
            index += 1
        }
    }

    // MARK: - Итог

    private var resultView: some View {
        VStack(spacing: 18) {
            GradientIcon(systemName: "party.popper.fill", size: 90)
            Text("Повторение завершено")
                .font(.title.bold())
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 12) {
                StatPill(value: "\(recalled)", caption: "помню", icon: "checkmark.circle.fill", color: Theme.success)
                StatPill(value: "\(forgotten)", caption: "повторить", icon: "arrow.counterclockwise", color: Theme.warning)
            }
            .padding(.horizontal, 24)

            Text(forgotten > 0
                 ? "Карточки, которые не вспомнились, вернутся сегодня же через несколько минут."
                 : "Все карточки вспомнились — следующая порция придёт по расписанию.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            Button("Готово") { dismiss() }
                .buttonStyle(BrandButtonStyle(expands: false))
        }
        .padding(30)
    }
}

// MARK: - Сводка для «Главной»

/// Сколько карточек ждёт повторения прямо сейчас.
enum ReviewQueue {
    static func dueCount(in notes: [Note]) -> Int {
        notes.flatMap(\.flashcards).count { $0.isNew || $0.isDue }
    }
}
