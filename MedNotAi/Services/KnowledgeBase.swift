import Foundation
import SwiftData

/// Кусок материала, который ассистент получает вместе с вопросом.
struct KnowledgeSnippet: Identifiable, Hashable {
    let id: UUID
    let title: String
    let text: String
    /// Откуда взято — показываем под ответом как источник.
    let source: String
}

/// Подбирает к вопросу подходящие фрагменты из конспектов пользователя и глоссария.
///
/// Без этого ассистент отвечал «вообще», игнорируя материал курса, — а студенту
/// нужен ответ по своей лекции, с той же терминологией, что спросят на экзамене.
/// Полноценные эмбеддинги здесь избыточны: конспектов у одного человека сотни,
/// а не миллионы, и обычное совпадение слов с учётом редкости работает быстро
/// и предсказуемо.
enum KnowledgeBase {

    /// Сколько фрагментов уходит в модель. Больше — дороже запрос и выше риск,
    /// что модель начнёт пересказывать всё подряд вместо ответа на вопрос.
    static let maxSnippets = 4
    private static let maxCharactersPerSnippet = 900

    static func snippets(for question: String, in context: ModelContext) -> [KnowledgeSnippet] {
        let terms = keywords(in: question)
        guard !terms.isEmpty else { return [] }
        guard let notes = try? context.fetch(FetchDescriptor<Note>()) else { return [] }

        var scored: [(note: Note, score: Double, paragraph: String)] = []
        for note in notes {
            guard let best = bestParagraph(of: note, matching: terms) else { continue }
            scored.append((note, best.score, best.text))
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(maxSnippets)
            .map { item in
                KnowledgeSnippet(
                    id: item.note.id,
                    title: item.note.displayTitle,
                    text: String(item.paragraph.prefix(maxCharactersPerSnippet)),
                    source: "\(item.note.displayTitle) · \(item.note.subject)"
                )
            }
    }

    /// Наиболее релевантный абзац конспекта. Целый конспект отдавать модели
    /// расточительно, а по одному предложению теряется контекст.
    private static func bestParagraph(of note: Note, matching terms: Set<String>) -> (text: String, score: Double)? {
        let titleBonus = score(of: note.title, terms: terms) * 2.5
        let paragraphs = note.body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 40 }

        var best: (text: String, score: Double)?
        for paragraph in paragraphs {
            let value = score(of: paragraph, terms: terms)
            if value > (best?.score ?? 0) {
                best = (paragraph, value)
            }
        }

        // Заголовок совпал, а тело — нет: конспект всё равно по теме.
        if best == nil, titleBonus > 0, !note.body.isEmpty {
            best = (String(note.body.prefix(maxCharactersPerSnippet)), titleBonus)
        }
        guard var result = best else { return nil }
        result.score += titleBonus
        return result.score > 0 ? result : nil
    }

    private static func score(of text: String, terms: Set<String>) -> Double {
        let haystack = text.lowercased()
        var total = 0.0
        for term in terms where haystack.contains(term) {
            // Длинное слово вроде «кардиомиоцит» отбирает конспект точнее,
            // чем короткое «тон», поэтому вес растёт с длиной.
            total += Double(term.count) / 4.0
        }
        return total
    }

    /// Значимые слова вопроса: без предлогов, союзов и вопросительных слов.
    static func keywords(in text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "что", "чем", "как", "где", "когда", "какой", "какая", "какие", "почему",
            "зачем", "кто", "это", "такое", "для", "при", "или", "and", "the", "and",
            "если", "она", "они", "его", "нужно", "надо", "быть", "есть", "может",
            "меня", "тебя", "весь", "всё", "все", "так", "там", "тут", "чтобы",
            "отличается", "разница", "между", "объясни", "расскажи", "напиши", "сделай"
        ]
        let separators = CharacterSet.alphanumerics.inverted
        return Set(
            text.lowercased()
                .components(separatedBy: separators)
                .filter { $0.count >= 4 && !stopWords.contains($0) }
        )
    }
}
