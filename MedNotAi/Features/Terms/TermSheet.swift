import SwiftUI

/// Всплывающая карточка с определением термина — «Подсказки по Терминам» из презентации.
struct TermSheet: View {
    let term: MedicalTerm

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TermDetailView(term: term)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { dismiss() }
                    }
                }
        }
    }
}

/// Содержимое карточки термина. Отдельный тип, чтобы смежные термины
/// открывались push-переходом внутри одного NavigationStack.
struct TermDetailView: View {
    let term: MedicalTerm

    @Environment(AIAssistant.self) private var assistant
    @Environment(\.colorScheme) private var scheme
    @State private var deepExplanation: String?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 13) {
                    GradientIcon(systemName: "character.book.closed.fill", size: 50)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(term.term.capitalizedFirst)
                            .font(.title2.bold())
                            .foregroundStyle(Theme.textPrimary)
                        TagChip(text: term.category, color: Theme.primary)
                    }
                    Spacer()
                }

                GlassCard {
                    Text(term.definition)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let deepExplanation {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles").foregroundStyle(Theme.accentPink)
                                Text("Разбор от ассистента")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            Text(deepExplanation)
                                .font(.callout)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Button {
                        Task { await loadDeepExplanation() }
                    } label: {
                        HStack(spacing: 8) {
                            if isLoading {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(isLoading ? "Ассистент думает…" : "Объяснить подробнее")
                        }
                    }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(isLoading)
                }

                if !related.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Смежные термины")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                        ForEach(related) { other in
                            NavigationLink {
                                TermDetailView(term: other)
                            } label: {
                                HStack {
                                    Text(other.term.capitalizedFirst)
                                        .font(.callout)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                                .background(Theme.cardFill(scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Color.clear.frame(height: 20)
            }
            .padding(20)
        }
        .background(AppBackground())
        .navigationTitle("Термин")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var related: [MedicalTerm] {
        MedicalGlossary.terms
            .filter { $0.category == term.category && $0.term != term.term }
            .prefix(4)
            .map { $0 }
    }

    private func loadDeepExplanation() async {
        isLoading = true
        defer { isLoading = false }
        do {
            deepExplanation = try await assistant.explain(term: term.term)
        } catch {
            deepExplanation = error.localizedDescription
        }
    }
}

// MARK: - Полный глоссарий

struct GlossaryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isWideLayout) private var isWide
    @State private var search = ""
    @State private var selectedCategory: String?
    @State private var selectedTerm: MedicalTerm?

    private var results: [MedicalTerm] {
        var items = MedicalGlossary.search(search)
        if let selectedCategory {
            items = items.filter { $0.category == selectedCategory }
        }
        return items
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 12) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                FilterChip(title: "Все", isOn: selectedCategory == nil) { selectedCategory = nil }
                                ForEach(MedicalGlossary.categories, id: \.self) { cat in
                                    FilterChip(title: cat, isOn: selectedCategory == cat) {
                                        selectedCategory = selectedCategory == cat ? nil : cat
                                    }
                                }
                            }
                        }

                        // На широком экране термины ложатся в две колонки.
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                                 count: isWide ? 2 : 1), spacing: 12) {
                            ForEach(results) { term in
                                Button { selectedTerm = term } label: {
                                    GlassCard {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(term.term.capitalizedFirst)
                                                    .font(.headline)
                                                    .foregroundStyle(Theme.textPrimary)
                                                Spacer()
                                                TagChip(text: term.category, color: Theme.primary)
                                            }
                                            Text(term.definition)
                                                .font(.subheadline)
                                                .foregroundStyle(Theme.textSecondary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 20)
                    .readableWidth(isWide ? 900 : Layout.contentMaxWidth)
                }
            }
            .navigationTitle("Глоссарий")
            .searchable(text: $search, prompt: "Поиск термина")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            // Шит уже окна, поэтому меряем его собственную ширину.
            .measuredWidth()
            .sheet(item: $selectedTerm) { TermSheet(term: $0).macSheetSize(height: 560) }
        }
    }
}
