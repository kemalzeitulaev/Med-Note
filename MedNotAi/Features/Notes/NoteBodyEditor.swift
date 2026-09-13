import SwiftUI

/// Редактор в духе Заметок: стили абзаца видны сразу, вставка — с панели.
struct NoteBodyEditor: View {
    @Binding var text: String
    var onInsertPhoto: () -> Void
    var onInsertCamera: (() -> Void)?
    var onInsertLecture: () -> Void
    var onInsertPDF: () -> Void

    var focusedID: FocusState<UUID?>.Binding

    @State private var blocks: [NoteBlock] = [NoteBlock(style: .body)]
    @State private var writing = false

    private var focusedStyle: NoteBlockStyle {
        blocks.first(where: { $0.id == focusedID.wrappedValue })?.style ?? .body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            formatBar
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    blockRow(block, index: index)
                }
            }
        }
        .onAppear(perform: reloadIfNeeded)
        .onChange(of: text) { _, _ in
            guard !writing else { return }
            reloadIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("Заголовок", systemImage: "textformat.size.larger") { apply(.heading) }
                Button("Список", systemImage: "list.bullet") { apply(.bullet) }
                Button("Дела", systemImage: "checklist") { apply(.checklist) }
                Button("Фото", systemImage: "photo") { onInsertPhoto() }
            }
        }
    }

    // MARK: - Панель как «Аа» в Заметках

    private var formatBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Menu {
                    ForEach([NoteBlockStyle.title, .heading, .subheading, .body, .quote], id: \.id) { style in
                        Button {
                            apply(style)
                        } label: {
                            Label(style.label, systemImage: style.icon)
                        }
                    }
                } label: {
                    formatChip("textformat.size", active: [.title, .heading, .subheading, .quote].contains(focusedStyle))
                }

                formatButton(.bullet)
                formatButton(.numbered)
                formatButton(.checklist)

                Menu {
                    Button("Заголовок", systemImage: "textformat.size.larger") { insert(.title) }
                    Button("Список", systemImage: "list.bullet") { insert(.bullet) }
                    Button("Список дел", systemImage: "checklist") { insert(.checklist) }
                    Divider()
                    Button("Фото", systemImage: "photo.badge.plus", action: onInsertPhoto)
                    if let onInsertCamera {
                        Button("Камера", systemImage: "camera.fill", action: onInsertCamera)
                    }
                    Button("Лекция", systemImage: "mic.fill", action: onInsertLecture)
                    Button("PDF / слайды", systemImage: "doc.badge.plus", action: onInsertPDF)
                } label: {
                    formatChip("plus", active: false)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func formatButton(_ style: NoteBlockStyle) -> some View {
        Button {
            apply(style)
        } label: {
            formatChip(style.icon, active: focusedStyle == style)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.label)
    }

    private func formatChip(_ icon: String, active: Bool) -> some View {
        Image(systemName: icon)
            .font(.body.weight(.semibold))
            .foregroundStyle(active ? Theme.primary : Theme.textPrimary)
            .frame(width: 36, height: 36)
            .background(active ? Theme.primary.opacity(0.14) : Theme.surfaceTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Строка абзаца

    private func blockRow(_ block: NoteBlock, index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            leading(block, index: index)
                .padding(.top, block.style == .title ? 8 : 6)

            TextField(block.style.placeholder, text: binding(for: block.id).text, axis: .vertical)
                .font(block.style.font)
                .foregroundStyle(block.style == .quote ? Theme.textSecondary : Theme.textPrimary)
                .strikethrough(block.style == .checklist && block.isChecked)
                .textFieldStyle(.plain)
                .focused(focusedID, equals: block.id)
        }
        .padding(.vertical, verticalPadding(for: block.style))
        .opacity(block.style == .checklist && block.isChecked ? 0.55 : 1)
    }

    @ViewBuilder
    private func leading(_ block: NoteBlock, index: Int) -> some View {
        switch block.style {
        case .bullet:
            Circle()
                .fill(Theme.primarySoft)
                .frame(width: 6, height: 6)
                .padding(.top, 8)
        case .numbered:
            Text("\(number(at: index)).")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.primary)
                .frame(width: 28, alignment: .trailing)
        case .checklist:
            Button {
                toggleCheck(id: block.id)
            } label: {
                Image(systemName: block.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(block.isChecked ? Theme.success : Theme.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(block.isChecked ? "Выполнено" : "Не выполнено")
        case .quote:
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.primary)
                .frame(width: 3, height: 22)
                .padding(.top, 4)
        default:
            EmptyView()
        }
    }

    private func verticalPadding(for style: NoteBlockStyle) -> CGFloat {
        switch style {
        case .title: 10
        case .heading: 8
        case .subheading: 6
        default: 2
        }
    }

    // MARK: - Правки

    private func binding(for id: UUID) -> Binding<NoteBlock> {
        Binding(
            get: { blocks.first(where: { $0.id == id }) ?? NoteBlock(style: .body) },
            set: { updated in
                guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
                var value = updated
                if let breakAt = value.text.firstIndex(of: "\n") {
                    let before = String(value.text[..<breakAt])
                    let after = String(value.text[value.text.index(after: breakAt)...])
                        .replacingOccurrences(of: "\n", with: " ")
                    value.text = before
                    blocks[idx] = value
                    let nextStyle: NoteBlockStyle = value.style.continuesOnReturn ? value.style : .body
                    let inserted = NoteBlock(style: nextStyle, text: after)
                    blocks.insert(inserted, at: idx + 1)
                    commit()
                    focusedID.wrappedValue = inserted.id
                    return
                }
                blocks[idx] = value
                commit()
            }
        )
    }

    private func apply(_ style: NoteBlockStyle) {
        let target = focusedID.wrappedValue ?? blocks.last?.id
        guard let id = target, let idx = blocks.firstIndex(where: { $0.id == id }) else {
            insert(style)
            return
        }
        if blocks[idx].style == style, style != .body {
            blocks[idx].style = .body
        } else {
            blocks[idx].style = style
            if style != .checklist { blocks[idx].isChecked = false }
        }
        commit()
        focusedID.wrappedValue = id
    }

    private func insert(_ style: NoteBlockStyle) {
        let at: Int = {
            if let id = focusedID.wrappedValue, let idx = blocks.firstIndex(where: { $0.id == id }) {
                return idx + 1
            }
            return blocks.count
        }()
        let block = NoteBlock(style: style)
        blocks.insert(block, at: min(at, blocks.count))
        commit()
        focusedID.wrappedValue = block.id
    }

    private func toggleCheck(id: UUID) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[idx].isChecked.toggle()
        commit()
    }

    private func number(at index: Int) -> Int {
        var value = 0
        for i in 0...index where blocks[i].style == .numbered {
            value += 1
        }
        return max(1, value)
    }

    private func commit() {
        writing = true
        text = NoteMarkup.serialize(blocks)
        writing = false
    }

    private func reloadIfNeeded() {
        let current = NoteMarkup.serialize(blocks)
        guard current != text else { return }
        blocks = NoteMarkup.parse(text)
        if focusedID.wrappedValue == nil { focusedID.wrappedValue = blocks.first?.id }
    }
}
