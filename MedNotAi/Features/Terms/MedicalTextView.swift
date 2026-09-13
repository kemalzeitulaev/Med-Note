import SwiftUI

/// Схема ссылок для тапабельных медицинских терминов.
enum TermLink {
    static let scheme = "mednote-term"

    static func url(for term: String) -> URL? {
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? term
        return URL(string: "\(scheme)://t/\(encoded)")
    }

    static func term(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let raw = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        return raw.removingPercentEncoding ?? raw
    }
}

@MainActor
enum MedicalTextRenderer {

    /// Разметка одного и того же текста запрашивается при каждой перерисовке,
    /// поэтому результат кэшируется. Кэш ограничен, чтобы не расти бесконечно.
    private static var cache: [String: AttributedString] = [:]
    private static let cacheLimit = 400

    static func attributed(_ text: String, highlightTerms: Bool) -> AttributedString {
        let key = (highlightTerms ? "1" : "0") + text
        if let cached = cache[key] { return cached }

        let result = render(text, highlightTerms: highlightTerms)
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }

    /// Преобразует markdown-текст в AttributedString и подсвечивает известные медицинские термины.
    private static func render(_ text: String, highlightTerms: Bool) -> AttributedString {
        var attr = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)

        guard highlightTerms else { return attr }

        let plain = String(attr.characters)
        let matches = MedicalGlossary.matches(in: plain)
        guard !matches.isEmpty else { return attr }

        for (range, term) in matches {
            let lowerOffset = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let upperOffset = plain.distance(from: plain.startIndex, to: range.upperBound)
            let chars = attr.characters
            guard lowerOffset < upperOffset, upperOffset <= chars.count else { continue }
            let start = chars.index(chars.startIndex, offsetBy: lowerOffset)
            let end = chars.index(chars.startIndex, offsetBy: upperOffset)

            attr[start..<end].foregroundColor = Theme.primaryDeep
            attr[start..<end].underlineStyle = Text.LineStyle(pattern: .dot, color: Theme.primarySoft)
            if let url = TermLink.url(for: term.term) {
                attr[start..<end].link = url
            }
        }
        return attr
    }
}

/// Отображает текст конспекта с заголовками как в Заметках и подсказками по терминам.
struct MedicalTextView: View {
    let text: String
    var highlightTerms: Bool = true
    var onTermTap: (MedicalTerm) -> Void
    var onChecklistToggle: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let name = TermLink.term(from: url), let term = MedicalGlossary.term(for: name) {
                onTermTap(term)
                return .handled
            }
            return .systemAction
        })
    }

    // MARK: Разбор на блоки

    private enum Block {
        case heading(String, level: Int)
        case bullet(String)
        case numbered(String, index: String)
        case checklist(String, checked: Bool, line: Int)
        case quote(String)
        case paragraph(String)
        case spacer
    }

    private var blocks: [Block] {
        text.components(separatedBy: .newlines).enumerated().map { offset, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .spacer }
            if line.hasPrefix("### ") { return .heading(String(line.dropFirst(4)), level: 3) }
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3)), level: 2) }
            if line.hasPrefix("# ") { return .heading(String(line.dropFirst(2)), level: 1) }
            if line.hasPrefix("- [ ] ") { return .checklist(String(line.dropFirst(6)), checked: false, line: offset) }
            if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                return .checklist(String(line.dropFirst(6)), checked: true, line: offset)
            }
            if line.hasPrefix("> ") { return .quote(String(line.dropFirst(2))) }
            if line.hasPrefix("• ") { return .bullet(String(line.dropFirst(2))) }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            if line.hasPrefix("* ") && !line.hasPrefix("**") { return .bullet(String(line.dropFirst(2))) }
            if let match = line.firstMatch(ofNumberedPrefix: true) {
                return .numbered(match.rest, index: match.number)
            }
            return .paragraph(line)
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .spacer:
            Color.clear.frame(height: 3)

        case .heading(let content, let level):
            Text(MedicalTextRenderer.attributed(content, highlightTerms: highlightTerms))
                .font(headingFont(level))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, level == 1 ? 14 : (level == 2 ? 12 : 8))
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .quote(let content):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.primary)
                    .frame(width: 3)
                Text(MedicalTextRenderer.attributed(content, highlightTerms: highlightTerms))
                    .font(.body)
                    .italic()
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

        case .checklist(let content, let checked, let line):
            Button {
                onChecklistToggle?(line)
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(checked ? Theme.success : Theme.primary)
                    Text(MedicalTextRenderer.attributed(content, highlightTerms: highlightTerms))
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .strikethrough(checked)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .opacity(checked ? 0.55 : 1)
            .disabled(onChecklistToggle == nil)

        case .bullet(let content):
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(Theme.primarySoft)
                    .frame(width: 5, height: 5)
                    .padding(.top, 8)
                Text(MedicalTextRenderer.attributed(content, highlightTerms: highlightTerms))
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .numbered(let content, let index):
            HStack(alignment: .top, spacing: 9) {
                Text(index)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Theme.brandGradient, in: Circle())
                Text(MedicalTextRenderer.attributed(content, highlightTerms: highlightTerms))
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .paragraph(let content):
            Text(MedicalTextRenderer.attributed(content, highlightTerms: highlightTerms))
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle.bold()
        case 2: .title2.bold()
        default: .title3.weight(.semibold)
        }
    }
}

private extension String {
    struct NumberedPrefix {
        let number: String
        let rest: String
    }

    /// Распознаёт строки вида «1. Текст».
    func firstMatch(ofNumberedPrefix: Bool) -> NumberedPrefix? {
        guard let dotIndex = firstIndex(of: ".") else { return nil }
        let numberPart = self[startIndex..<dotIndex]
        guard !numberPart.isEmpty, numberPart.count <= 2, numberPart.allSatisfy(\.isNumber) else { return nil }
        let rest = self[index(after: dotIndex)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return NumberedPrefix(number: String(numberPart), rest: rest)
    }
}
