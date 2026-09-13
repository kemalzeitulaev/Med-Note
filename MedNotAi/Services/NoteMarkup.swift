import SwiftUI

/// Стили абзаца — как меню «Аа» в Заметках: заголовок, список, чеклист.
enum NoteBlockStyle: String, CaseIterable, Identifiable {
    case title, heading, subheading, body, bullet, numbered, checklist, quote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Заголовок"
        case .heading: "Заголовок 2"
        case .subheading: "Подзаголовок"
        case .body: "Основной текст"
        case .bullet: "Маркированный список"
        case .numbered: "Нумерованный список"
        case .checklist: "Список дел"
        case .quote: "Цитата"
        }
    }

    var icon: String {
        switch self {
        case .title: "textformat.size.larger"
        case .heading: "textformat.size"
        case .subheading: "textformat"
        case .body: "text.alignleft"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .checklist: "checklist"
        case .quote: "text.quote"
        }
    }

    var placeholder: String {
        switch self {
        case .title: "Заголовок"
        case .heading: "Заголовок раздела"
        case .subheading: "Подзаголовок"
        case .body: "Начните писать"
        case .bullet, .numbered: "Пункт списка"
        case .checklist: "Дело"
        case .quote: "Цитата"
        }
    }

    var font: Font {
        switch self {
        case .title: .largeTitle.bold()
        case .heading: .title2.bold()
        case .subheading: .title3.weight(.semibold)
        default: .body
        }
    }

    var continuesOnReturn: Bool {
        switch self {
        case .bullet, .numbered, .checklist: true
        default: false
        }
    }
}

struct NoteBlock: Identifiable, Equatable {
    var id: UUID
    var style: NoteBlockStyle
    var text: String
    var isChecked: Bool

    init(id: UUID = UUID(), style: NoteBlockStyle, text: String = "", isChecked: Bool = false) {
        self.id = id
        self.style = style
        self.text = text
        self.isChecked = isChecked
    }
}

/// Разбор и сборка markdown, которым уже пользуется ИИ и импорт.
enum NoteMarkup {
    static func parse(_ source: String) -> [NoteBlock] {
        if source.isEmpty { return [NoteBlock(style: .body)] }
        var blocks: [NoteBlock] = []
        for raw in source.components(separatedBy: "\n") {
            blocks.append(parseLine(raw))
        }
        if blocks.isEmpty { blocks = [NoteBlock(style: .body)] }
        return blocks
    }

    static func serialize(_ blocks: [NoteBlock]) -> String {
        guard !blocks.isEmpty else { return "" }
        var numbered = 0
        return blocks.map { block in
            let text = block.text
            switch block.style {
            case .title: return "# \(text)"
            case .heading: return "## \(text)"
            case .subheading: return "### \(text)"
            case .body: return text
            case .bullet: return text.isEmpty ? "-" : "- \(text)"
            case .numbered:
                numbered += 1
                return text.isEmpty ? "\(numbered)." : "\(numbered). \(text)"
            case .checklist:
                let mark = block.isChecked ? "x" : " "
                return text.isEmpty ? "- [\(mark)]" : "- [\(mark)] \(text)"
            case .quote: return text.isEmpty ? ">" : "> \(text)"
            }
        }
        .joined(separator: "\n")
    }

    static func toggleChecklist(in source: String, lineIndex: Int) -> String {
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return source }
        var line = lines[lineIndex]
        if line.contains("- [ ]") {
            line = line.replacingOccurrences(of: "- [ ]", with: "- [x]")
        } else if line.contains("- [x]") || line.contains("- [X]") {
            line = line.replacingOccurrences(of: "- [x]", with: "- [ ]")
                .replacingOccurrences(of: "- [X]", with: "- [ ]")
        } else {
            return source
        }
        lines[lineIndex] = line
        return lines.joined(separator: "\n")
    }

    private static func parseLine(_ raw: String) -> NoteBlock {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("##") {
            return NoteBlock(style: .title, text: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("### ") {
            return NoteBlock(style: .subheading, text: String(trimmed.dropFirst(4)))
        }
        if trimmed.hasPrefix("## ") {
            return NoteBlock(style: .heading, text: String(trimmed.dropFirst(3)))
        }
        if let check = checklist(trimmed) { return check }
        if trimmed.hasPrefix("> ") {
            return NoteBlock(style: .quote, text: String(trimmed.dropFirst(2)))
        }
        if trimmed == ">" { return NoteBlock(style: .quote) }
        if trimmed.hasPrefix("• ") {
            return NoteBlock(style: .bullet, text: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("- ") {
            return NoteBlock(style: .bullet, text: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("* ") && !trimmed.hasPrefix("**") {
            return NoteBlock(style: .bullet, text: String(trimmed.dropFirst(2)))
        }
        if trimmed == "-" || trimmed == "•" || trimmed == "*" {
            return NoteBlock(style: .bullet)
        }
        if let numbered = numbered(trimmed) { return numbered }
        return NoteBlock(style: .body, text: raw.hasPrefix(" ") ? raw : trimmed)
    }

    private static func checklist(_ line: String) -> NoteBlock? {
        let patterns: [(prefix: String, checked: Bool)] = [
            ("- [x] ", true), ("- [X] ", true), ("- [ ] ", false),
            ("* [x] ", true), ("* [ ] ", false)
        ]
        for item in patterns where line.hasPrefix(item.prefix) {
            return NoteBlock(style: .checklist, text: String(line.dropFirst(item.prefix.count)), isChecked: item.checked)
        }
        if line == "- [ ]" || line == "- []" { return NoteBlock(style: .checklist, isChecked: false) }
        if line == "- [x]" || line == "- [X]" { return NoteBlock(style: .checklist, isChecked: true) }
        return nil
    }

    private static func numbered(_ line: String) -> NoteBlock? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let num = line[line.startIndex..<dot]
        guard !num.isEmpty, num.count <= 3, num.allSatisfy(\.isNumber) else { return nil }
        let rest = line[line.index(after: dot)...]
        if rest.isEmpty { return NoteBlock(style: .numbered) }
        guard rest.first == " " else { return nil }
        return NoteBlock(style: .numbered, text: rest.dropFirst().trimmingCharacters(in: .whitespaces))
    }
}
