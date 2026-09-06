import Foundation

struct AIMessage: Codable {
    let role: String   // "system" | "user" | "assistant"
    let content: String
}

enum AIError: LocalizedError {
    case notConfigured
    case unauthorized
    case rateLimited
    case serverUnavailable(Int)
    case network
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "ИИ-провайдер не настроен. Добавьте API-ключ в «Профиль → Настройки ИИ»."
        case .unauthorized:
            "Провайдер отклонил ключ. Проверьте API-ключ и доступ к выбранной модели."
        case .rateLimited:
            "Слишком много запросов подряд. Подождите примерно минуту и повторите."
        case .serverUnavailable(let code):
            "Сервис ИИ временно недоступен (код \(code)). Попробуйте позже."
        case .network:
            "Нет связи с сервисом ИИ. Проверьте интернет-соединение."
        case .emptyReply:
            "Модель вернула пустой ответ. Переформулируйте вопрос."
        }
    }
}

protocol AIProviding: Sendable {
    func complete(messages: [AIMessage], temperature: Double) async throws -> String
}

// MARK: - Реальный провайдер (OpenAI-совместимый API)

struct OpenAICompatibleProvider: AIProviding {
    let baseURL: String
    let apiKey: String
    let model: String

    func complete(messages: [AIMessage], temperature: Double) async throws -> String {
        guard !apiKey.isEmpty, let url = URL(string: baseURL + "/chat/completions") else {
            throw AIError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        struct Payload: Encodable {
            let model: String
            let messages: [AIMessage]
            let temperature: Double
        }
        request.httpBody = try JSONEncoder().encode(
            Payload(model: model, messages: messages, temperature: temperature)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIError.network
        }

        guard let http = response as? HTTPURLResponse else { throw AIError.network }
        guard (200..<300).contains(http.statusCode) else {
            // Тело ответа не показываем: провайдеры возвращают в нём
            // фрагменты запроса и служебные идентификаторы, а иногда и сам ключ.
            switch http.statusCode {
            case 401, 403: throw AIError.unauthorized
            case 429: throw AIError.rateLimited
            default: throw AIError.serverUnavailable(http.statusCode)
            }
        }

        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw AIError.emptyReply
        }
        let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw AIError.emptyReply }
        return text
    }
}

// MARK: - Тип вопроса

/// Что именно спросили. От этого зависит форма ответа: определение,
/// сравнение и «как лечить» требуют разной структуры, и подставлять
/// под все случаи один шаблон — верный способ получить воду вместо ответа.
enum QuestionIntent {
    case definition(String)
    case comparison(String, String)
    case mechanism
    case clinical
    case management
    case list
    case general

    static func detect(in question: String) -> QuestionIntent {
        let text = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if let pair = comparisonPair(in: text) { return .comparison(pair.0, pair.1) }
        if let subject = definitionSubject(in: text) { return .definition(subject) }

        if text.contains("патогенез") || text.contains("механизм") || text.contains("почему")
            || text.contains("как развива") {
            return .mechanism
        }
        if text.contains("лечен") || text.contains("терап") || text.contains("тактик")
            || text.contains("препарат") || text.contains("что делать") {
            return .management
        }
        if text.contains("симптом") || text.contains("клиник") || text.contains("проявл")
            || text.contains("диагност") || text.contains("признак") {
            return .clinical
        }
        if text.contains("перечисли") || text.contains("список") || text.contains("назови")
            || text.contains("виды") || text.contains("классификац") {
            return .list
        }
        return .general
    }

    private static func comparisonPair(in text: String) -> (String, String)? {
        let patterns = ["чем отличается", "отличие", "отличия", "разница между", "разницу между",
                        "чем отличаются", "сравни"]
        guard patterns.contains(where: { text.contains($0) }) else { return nil }

        // «чем отличается А от Б» и «разница между А и Б»
        for separator in [" от ", " и ", " vs ", " или "] {
            guard let range = text.range(of: separator) else { continue }
            let left = cleanSubject(String(text[text.startIndex..<range.lowerBound]))
            let right = cleanSubject(String(text[range.upperBound...]))
            if !left.isEmpty, !right.isEmpty { return (left, right) }
        }
        return nil
    }

    private static func definitionSubject(in text: String) -> String? {
        for prefix in ["что такое", "что значит", "что означает", "определение", "дай определение"] {
            guard let range = text.range(of: prefix) else { continue }
            let subject = cleanSubject(String(text[range.upperBound...]))
            if !subject.isEmpty { return subject }
        }
        return nil
    }

    private static func cleanSubject(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " ?!.,:;«»\"'()"))
        for noise in ["чем отличается", "чем отличаются", "разница между", "разницу между",
                      "отличие", "отличия", "сравни", "такое", "это"] {
            value = value.replacingOccurrences(of: noise, with: "")
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " ?!.,:;«»\"'()"))
    }
}

// MARK: - Демо-провайдер (работает офлайн, без ключа)

/// Собирает ответ из локального глоссария и конспектов пользователя.
/// Нужен, чтобы приложение было полезным и без API-ключа.
struct DemoAIProvider: AIProviding {

    func complete(messages: [AIMessage], temperature: Double) async throws -> String {
        // Небольшая пауза имитирует работу модели, но прерывается вместе с задачей —
        // иначе закрытый экран продолжал бы «думать» ещё полсекунды.
        try await Task.sleep(for: .milliseconds(400 + Int.random(in: 0...300)))
        let prompt = messages.last(where: { $0.role == "user" })?.content ?? ""
        return Self.reply(for: prompt)
    }

    static func reply(for prompt: String) -> String {
        if prompt.hasPrefix(AIAssistant.Prompts.structurePrefix) {
            return structuredNote(from: String(prompt.dropFirst(AIAssistant.Prompts.structurePrefix.count)))
        }
        if prompt.hasPrefix(AIAssistant.Prompts.summaryPrefix) {
            return summary(from: String(prompt.dropFirst(AIAssistant.Prompts.summaryPrefix.count)))
        }
        if prompt.hasPrefix(AIAssistant.Prompts.flashcardsPrefix) {
            return flashcards(from: String(prompt.dropFirst(AIAssistant.Prompts.flashcardsPrefix.count)))
        }
        if prompt.hasPrefix(AIAssistant.Prompts.explainPrefix) {
            return explanation(for: String(prompt.dropFirst(AIAssistant.Prompts.explainPrefix.count)))
        }
        return chatAnswer(for: prompt)
    }

    // MARK: Ответ в чате

    /// Отвечает по существу заданного вопроса: сначала прямой ответ,
    /// затем детали и только в конце — что делать дальше.
    private static func chatAnswer(for rawPrompt: String) -> String {
        // Вопрос приходит вместе с выдержками из конспектов — отделяем их.
        let parts = rawPrompt.components(separatedBy: AIAssistant.Prompts.contextSeparator)
        let question = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let notesContext = parts.count > 1 ? parts[1] : ""

        var blocks: [String] = []

        switch QuestionIntent.detect(in: question) {
        case .comparison(let left, let right):
            blocks.append(comparisonAnswer(left, right))
        case .definition(let subject):
            blocks.append(definitionAnswer(for: subject, fallbackQuestion: question))
        case .mechanism, .clinical, .management, .list, .general:
            blocks.append(topicAnswer(for: question))
        }

        if !notesContext.isEmpty {
            blocks.append("**Из ваших конспектов**\n" + notesContext.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        blocks.append(demoFooter)
        return blocks.joined(separator: "\n\n")
    }

    private static func comparisonAnswer(_ left: String, _ right: String) -> String {
        let first = MedicalGlossary.bestMatch(for: left)
        let second = MedicalGlossary.bestMatch(for: right)

        guard let first, let second else {
            let known = [first, second].compactMap { $0 }
            var text = "Сравнение «\(left)» и «\(right)».\n\n"
            if known.isEmpty {
                text += "Ни один из терминов не найден в офлайн-словаре. Сравнивать удобно по одной сетке: определение → механизм → клиника → диагностика → тактика."
            } else {
                text += known.map { "**\($0.term.capitalizedFirst)** — \($0.definition)" }.joined(separator: "\n\n")
                text += "\n\nВторой термин в офлайн-словаре отсутствует."
            }
            return text
        }

        var text = "**\(first.term.capitalizedFirst)** — \(first.definition)\n\n"
        text += "**\(second.term.capitalizedFirst)** — \(second.definition)\n\n"
        text += "**Ключевое различие**\n"
        text += first.category == second.category
            ? "Оба понятия относятся к разделу «\(first.category)», поэтому различие ищите в механизме и клинических последствиях, а не в классификации."
            : "Понятия из разных разделов: «\(first.term)» относится к разделу «\(first.category)», «\(second.term)» — к разделу «\(second.category)»."
        return text
    }

    private static func definitionAnswer(for subject: String, fallbackQuestion: String) -> String {
        guard let term = MedicalGlossary.bestMatch(for: subject) else {
            let size = pluralRu(MedicalGlossary.terms.count, "статьи", "статей", "статей")
            return "Термин «\(subject)» не найден в офлайн-словаре из \(size).\n\nПодключите ИИ-провайдера в «Профиль → Настройки ИИ», чтобы получить развёрнутый ответ, или уточните написание термина."
        }
        var text = "**\(term.term.capitalizedFirst)** — \(term.definition)\n\n"
        text += "**Раздел:** \(term.category)"
        let neighbours = related(to: term)
        if !neighbours.isEmpty {
            text += "\n\n**Рядом по теме**\n"
            text += neighbours.map { "• \($0.term.capitalizedFirst) — \($0.definition.firstSentence)" }.joined(separator: "\n")
        }
        return text
    }

    /// Вопрос без явного шаблона: отвечаем по найденным в нём терминам.
    private static func topicAnswer(for question: String) -> String {
        let found = MedicalGlossary.matches(in: question).map(\.term)
        guard let main = found.first else {
            return "В офлайн-словаре нет терминов из этого вопроса, поэтому конкретного ответа дать не могу.\n\nПодключите ИИ-провайдера в «Профиль → Настройки ИИ» — тогда ассистент ответит на любой вопрос. Либо переформулируйте с использованием медицинского термина."
        }

        var text = "**\(main.term.capitalizedFirst)** — \(main.definition)\n\n"
        let others = found.dropFirst().prefix(3)
        if !others.isEmpty {
            text += "**Также упомянуто в вопросе**\n"
            text += others.map { "• \($0.term.capitalizedFirst) — \($0.definition.firstSentence)" }.joined(separator: "\n")
        }
        return text
    }

    private static let demoFooter =
        "_Демо-режим: ответ собран из встроенного словаря. Подключите API-ключ в «Профиль → Настройки ИИ», чтобы получать полноценные ответы модели._"

    private static func related(to term: MedicalTerm) -> [MedicalTerm] {
        MedicalGlossary.terms
            .filter { $0.category == term.category && $0.term != term.term }
            .prefix(3)
            .map { $0 }
    }

    // MARK: Структурирование конспекта

    private static func structuredNote(from text: String) -> String {
        let sentences = sentences(in: text)
        guard !sentences.isEmpty else {
            return "## Конспект\n\nТекст пуст — добавьте материал лекции, и я разложу его по разделам."
        }

        let terms = MedicalGlossary.matches(in: text).map(\.term)
        let uniqueTerms = Array(Set(terms.map(\.term))).sorted()
        let chunk = max(1, sentences.count / 3)

        var out = "## Основные положения\n"
        for s in sentences.prefix(chunk) { out += "• \(s)\n" }

        if sentences.count > chunk {
            out += "\n## Механизмы и детали\n"
            for s in sentences.dropFirst(chunk).prefix(chunk) { out += "• \(s)\n" }
        }
        if sentences.count > chunk * 2 {
            out += "\n## Клиническое значение\n"
            for s in sentences.dropFirst(chunk * 2) { out += "• \(s)\n" }
        }
        if !uniqueTerms.isEmpty {
            out += "\n## Ключевые термины\n"
            for t in uniqueTerms.prefix(8) { out += "• \(t.capitalizedFirst)\n" }
        }
        out += "\n## Вопросы для самопроверки\n"
        for q in questions(from: sentences) { out += "• \(q)\n" }
        return out
    }

    // MARK: Краткая выжимка

    private static func summary(from text: String) -> String {
        let all = sentences(in: text)
        guard !all.isEmpty else { return "Недостаточно текста для выжимки." }
        // Берём самые содержательные предложения, но выводим в исходном порядке.
        let keyIndices = all.enumerated()
            .sorted { $0.element.count > $1.element.count }
            .prefix(3)
            .map(\.offset)
            .sorted()
        return keyIndices.map { "• \(all[$0])" }.joined(separator: "\n")
    }

    // MARK: Флеш-карты

    private static func flashcards(from text: String) -> String {
        let terms = MedicalGlossary.matches(in: text).map(\.term)
        var seen = Set<String>()
        var lines: [String] = []

        for t in terms where !seen.contains(t.term) {
            seen.insert(t.term)
            lines.append("Q: Что такое «\(t.term)»?\nA: \(t.definition)")
            if lines.count >= 6 { break }
        }

        if lines.isEmpty {
            for s in sentences(in: text).prefix(5) {
                let words = s.split(separator: " ")
                guard words.count > 4 else { continue }
                let head = words.prefix(4).joined(separator: " ")
                lines.append("Q: Продолжите: «\(head)…»\nA: \(s)")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: Объяснение термина

    private static func explanation(for term: String) -> String {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = MedicalGlossary.bestMatch(for: clean) {
            return """
            \(known.definition)

            **Раздел:** \(known.category)
            """
        }
        return "Термин «\(clean)» отсутствует в офлайн-словаре. Подключите ИИ-провайдера в настройках, чтобы получить объяснение от модели."
    }

    // MARK: Утилиты

    /// Делит текст на предложения, сохраняя весь материал: короткие фрагменты
    /// (аббревиатуры вроде «ЭКГ.», сокращения «т.е.») присоединяются к предыдущему,
    /// а не отбрасываются — иначе структурирование теряло бы часть конспекта.
    private static func sentences(in text: String) -> [String] {
        let pieces = text
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        for piece in pieces {
            if piece.count < 12, var last = result.popLast() {
                last += ". " + piece
                result.append(last)
            } else {
                result.append(piece)
            }
        }
        return result
    }

    private static func questions(from sentences: [String]) -> [String] {
        sentences.prefix(3).enumerated().map { idx, s in
            let head = s.split(separator: " ").prefix(6).joined(separator: " ")
            return "Вопрос \(idx + 1): раскройте тезис «\(head)…»"
        }
    }
}

// MARK: - Фасад ассистента

@Observable
final class AIAssistant {
    static let shared = AIAssistant()

    /// Служебные метки: по ним демо-провайдер понимает тип запроса,
    /// а выдержки из конспектов отделяются от самого вопроса.
    enum Prompts {
        static let structurePrefix = "[структурировать]"
        static let summaryPrefix = "[выжимка]"
        static let flashcardsPrefix = "[карточки]"
        static let explainPrefix = "[термин]"
        static let contextSeparator = "\n\n===МАТЕРИАЛ==="
    }

    var isProcessing = false
    var lastError: String?

    private var settings: AppSettings { AppSettings.shared }

    private var provider: AIProviding {
        if settings.isLiveAIConfigured {
            return OpenAICompatibleProvider(
                baseURL: settings.normalizedBaseURL,
                apiKey: settings.apiKey,
                model: settings.model
            )
        }
        return DemoAIProvider()
    }

    var isDemoMode: Bool { !settings.isLiveAIConfigured }

    /// Базовые правила поведения. Формулировки намеренно жёсткие:
    /// без прямого запрета модели начинают ответ с пересказа вопроса
    /// и общего плана разбора вместо самого ответа.
    private var systemPrompt: String {
        """
        Ты — MedNoteAi, ассистент студента-медика. Отвечай на \(settings.language.promptName) языке.

        Правила ответа:
        1. Первая фраза — прямой ответ на заданный вопрос. Не пересказывай вопрос, \
        не пиши вступлений вроде «давайте разберёмся» и не предлагай план разбора.
        2. Отвечай только на то, о чём спросили. Спросили определение — дай определение, \
        а не всю нозологию. Спросили отличие — назови отличия, а не два независимых описания.
        3. Держись объёма: 3–8 предложений или до 7 пунктов списка. Разворачивай подробно, \
        только если об этом попросили явно.
        4. Конкретика вместо общих слов: называй цифры, сроки, дозы, критерии, названия проб и шкал.
        5. Если данных не хватает или вопрос неоднозначен — скажи об этом одной строкой \
        и задай один уточняющий вопрос. Не выдумывай факты и не подменяй их рассуждением.
        6. Если в блоке МАТЕРИАЛ есть выдержки из конспектов пользователя — опирайся на них \
        и отмечай, когда общепринятые данные расходятся с конспектом.
        7. Это учебный материал. Никаких назначений конкретному пациенту.
        """
    }

    // MARK: Публичные операции

    /// Отвечает на вопрос, опираясь на конспекты пользователя.
    func chat(history: [ChatMessage],
              newMessage: String,
              knowledge: [KnowledgeSnippet] = []) async throws -> String {
        var msgs: [AIMessage] = [.init(role: "system", content: systemPrompt)]
        // Хвоста истории хватает для поддержания темы, а весь диалог целиком
        // размывает вопрос и упирается в лимит контекста.
        for m in history.suffix(12) where !m.isError {
            msgs.append(.init(role: m.role.rawValue, content: m.text))
        }
        msgs.append(.init(role: "system", content: intentInstruction(for: newMessage)))
        msgs.append(.init(role: "user", content: newMessage + knowledgeBlock(knowledge)))
        // Низкая температура: фактический ответ важнее разнообразия формулировок.
        return try await run(msgs, temperature: 0.15)
    }

    /// Дополнительная рамка под тип вопроса: без неё модель часто
    /// отвечает «вообще про тему», а не на заданный вопрос.
    private func intentInstruction(for question: String) -> String {
        switch QuestionIntent.detect(in: question) {
        case .definition:
            return "Спросили определение. Первая фраза — само определение. Дальше не больше двух уточнений. Клинику, лечение и классификацию не перечисляй."
        case .comparison(let left, let right):
            return "Спросили, чем «\(left)» отличается от «\(right)». Ответь списком из 3–6 пунктов именно про различия. Не пиши два отдельных описания."
        case .mechanism:
            return "Спросили про механизм или патогенез. Разложи причинно-следственную цепочку по шагам. Не уходи в лечение, если об этом не спросили."
        case .clinical:
            return "Спросили про клинику или диагностику. Дай признаки, критерии и отличия от похожих состояний. Без общих слов вроде «зависит от случая»."
        case .management:
            return "Спросили про тактику. Это учебный разбор, не назначение пациенту. Назови принципы и типичные группы препаратов, если они общеприняты."
        case .list:
            return "Спросили перечень или классификацию. Ответь нумерованным или маркированным списком без вступления."
        case .general:
            return "Ответь строго на заданный вопрос. Если в вопросе несколько частей — разбери каждую отдельно."
        }
    }

    private func knowledgeBlock(_ snippets: [KnowledgeSnippet]) -> String {
        guard !snippets.isEmpty else { return "" }
        let body = snippets
            .map { "«\($0.title)»: \($0.text)" }
            .joined(separator: "\n\n")
        return Prompts.contextSeparator + "\n" + body
    }

    func structure(noteBody: String) async throws -> String {
        try await task(Prompts.structurePrefix, payload: noteBody, temperature: 0.2, instruction: """
        Преобразуй конспект лекции в структуру с заголовками (##) и маркированными списками.
        Сохрани каждый факт из исходного текста, ничего не добавляй от себя и не сокращай смысл.
        В конце добавь раздел «## Вопросы для самопроверки» с 3–5 вопросами.
        Верни только сам конспект, без комментариев о проделанной работе.
        """)
    }

    func summarize(_ text: String) async throws -> String {
        try await task(Prompts.summaryPrefix, payload: text, temperature: 0.2, instruction: """
        Сделай выжимку в 3–5 маркированных пунктах: только факты, которые спросят на экзамене.
        Каждый пункт — одно законченное утверждение с конкретикой (цифры, сроки, критерии).
        Без вступлений и без заключения.
        """)
    }

    /// Возвращает пары «вопрос — ответ» для флеш-карт.
    func makeFlashcards(from text: String) async throws -> [(question: String, answer: String)] {
        let raw = try await task(Prompts.flashcardsPrefix, payload: text, temperature: 0.3, instruction: """
        Составь 5–8 флеш-карт по тексту. Вопрос должен проверять понимание, а не узнавание:
        спрашивай про механизмы, критерии, сроки и отличия, а не «что такое X».
        Ответ — 1–2 предложения строго по тексту.
        Формат без нумерации и без лишних слов:
        Q: вопрос
        A: ответ

        Между карточками — пустая строка.
        """)
        return parseFlashcards(raw)
    }

    func explain(term: String) async throws -> String {
        try await task(Prompts.explainPrefix, payload: term, temperature: 0.2, instruction: """
        Объясни медицинский термин в 2–4 предложениях: определение, клиническое значение,
        типичный контекст употребления. Без вступлений и без списков.
        """)
    }

    // MARK: Внутреннее

    private func task(_ prefix: String,
                      payload: String,
                      temperature: Double,
                      instruction: String) async throws -> String {
        let messages: [AIMessage] = [
            .init(role: "system", content: systemPrompt + "\n\n" + instruction),
            .init(role: "user", content: prefix + payload)
        ]
        return try await run(messages, temperature: temperature)
    }

    @MainActor
    private func run(_ messages: [AIMessage], temperature: Double) async throws -> String {
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }
        do {
            return try await provider.complete(messages: messages, temperature: temperature)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func parseFlashcards(_ raw: String) -> [(question: String, answer: String)] {
        var result: [(String, String)] = []
        var currentQ: String?
        var currentA: String?

        func flush() {
            if let q = currentQ, let a = currentA, !q.isEmpty, !a.isEmpty {
                result.append((q, a))
            }
            currentQ = nil
            currentA = nil
        }

        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Q:") || t.hasPrefix("В:") {
                flush()
                currentQ = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("A:") || t.hasPrefix("О:") {
                currentA = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if !t.isEmpty, currentA != nil {
                currentA! += " " + t
            }
        }
        flush()
        return result
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }

    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }

    /// Первое предложение — для компактных подсказок в списках.
    var firstSentence: String {
        guard let end = firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) else { return self }
        return String(self[startIndex...end])
    }
}
