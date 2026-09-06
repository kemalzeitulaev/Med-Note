import SwiftUI
import StoreKit

/// Экран подписки. Оплата идёт через In-App Purchase — правила App Store
/// не разрешают проводить подписку на цифровой контент другим способом,
/// включая Apple Pay. Пользователь всё равно платит картой из Wallet,
/// подтверждая покупку через Face ID или Touch ID.
struct PaywallView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var store = StoreService.shared
    @State private var selectedProductID: String?
    @State private var showPromoCode = false
    @State private var pendingMessage: String?

    private let features: [(icon: String, title: String, text: String)] = [
        ("infinity", "Безлимитный ИИ-ассистент", "Разбор тем, объяснение терминов и подготовка к экзаменам без ограничений."),
        ("wand.and.stars", "Автоструктурирование конспектов", "ИИ превращает сырой текст лекции в готовый структурированный конспект."),
        ("rectangle.on.rectangle.angled", "Флеш-карты и интервальное повторение", "Автогенерация карточек из любого конспекта и расписание повторов."),
        ("person.2.fill", "Групповое конспектирование", "Общая база знаний курса и совместная работа."),
        ("nosign", "Без рекламы", "Ничто не будет отвлекать от подготовки."),
        ("globe", "Все языки", "Ассистент отвечает на языке вашего обучения.")
    ]

    private var selectedProduct: Product? {
        store.products.first { $0.id == selectedProductID } ?? store.products.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 20) {
                        header
                        if settings.tier == .promo { promoActiveCard }
                        plansPicker
                        featureList
                        actions
                        disclaimer
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 26)
                    .readableWidth(560)
                }
            }
            .navigationTitle("Premium")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .sheet(isPresented: $showPromoCode) { PromoCodeView().macSheetSize(height: 560) }
            .alert("Покупка ожидает подтверждения", isPresented: Binding(
                get: { pendingMessage != nil },
                set: { if !$0 { pendingMessage = nil } }
            )) {
                Button("Понятно") { pendingMessage = nil }
            } message: {
                Text(pendingMessage ?? "")
            }
        }
        .task { await store.load() }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(spacing: 12) {
            GradientIcon(systemName: "crown.fill", size: 84)
            Text("MedNoteAi Premium")
                .font(.title.bold())
                .foregroundStyle(Theme.textPrimary)
            Text(store.hasActiveSubscription
                 ? "Подписка активна — все возможности открыты"
                 : "Полный доступ ко всем возможностям ассистента")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Тарифы

    @ViewBuilder
    private var plansPicker: some View {
        if store.isLoading {
            ProgressView("Загружаем тарифы…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        } else if store.products.isEmpty {
            storeUnavailableCard
        } else {
            HStack(spacing: 11) {
                ForEach(store.products, id: \.id) { product in
                    planCard(product)
                }
            }
        }
    }

    private func planCard(_ product: Product) -> some View {
        let isSelected = selectedProduct?.id == product.id
        let badge = store.monthly.flatMap { product.savingsPercent(comparedToMonthly: $0) }

        return Button {
            withAnimation(.spring(duration: 0.25)) { selectedProductID = product.id }
        } label: {
            VStack(spacing: 5) {
                Text(product.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : Theme.textSecondary)
                    .lineLimit(1)
                Text(product.displayPrice)
                    .font(.title2.bold())
                    .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(badge.map { "экономия \($0)%" } ?? product.localizedPeriodPrice.replacingOccurrences(of: product.displayPrice + " ", with: ""))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : Theme.accentPink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.brandGradient)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.cardFill(scheme))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Товары не загрузились: нет сети либо подписки ещё не заведены
    /// в App Store Connect. Промокод в этом случае остаётся рабочим путём.
    private var storeUnavailableCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.warning)
                    Text("Тарифы недоступны")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Text("Не удалось получить список подписок из App Store. Проверьте соединение и попробуйте ещё раз — или активируйте промокод.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Button("Повторить") {
                    Task { await store.load() }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.primary)
            }
        }
    }

    // MARK: - Возможности

    private var featureList: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 15) {
                ForEach(features, id: \.title) { feature in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: feature.icon)
                            .font(.callout)
                            .foregroundStyle(Theme.primary)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(feature.text)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Кнопки

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 11) {
            if store.hasActiveSubscription {
                Button("Управлять подпиской") {
                    Task { await store.manageSubscriptions() }
                }
                .buttonStyle(BrandButtonStyle())
            } else if let product = selectedProduct {
                Button {
                    Task { await buy(product) }
                } label: {
                    HStack(spacing: 8) {
                        if store.isPurchasing { ProgressView().controlSize(.small).tint(.white) }
                        Text(purchaseTitle(for: product))
                    }
                }
                .buttonStyle(BrandButtonStyle())
                .disabled(store.isPurchasing)
            }

            if !store.hasActiveSubscription {
                Button("Восстановить покупки") {
                    Task { await store.restore() }
                }
                .buttonStyle(SoftButtonStyle(expands: true))
                .disabled(store.isPurchasing)
            }

            if settings.canStartTrial {
                Button("Сначала попробовать бесплатно 7 дней") {
                    settings.startTrial()
                    dismiss()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.primary)
            }

            if settings.tier != .promo {
                Button("У меня есть промокод") { showPromoCode = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primary)
            }

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func purchaseTitle(for product: Product) -> String {
        if let days = product.introductoryTrialDays {
            return "\(pluralRu(days, "день", "дня", "дней")) бесплатно, затем \(product.displayPrice)"
        }
        return "Оформить за \(product.localizedPeriodPrice)"
    }

    private func buy(_ product: Product) async {
        switch await store.purchase(product) {
        case .purchased:
            dismiss()
        case .pending:
            pendingMessage = "Покупку должен подтвердить владелец семейного доступа или банк. Premium включится автоматически, как только подтверждение придёт."
        case .cancelled:
            break
        }
    }

    /// Промо-доступ уже открывает всё, поэтому подписку предлагать незачем.
    private var promoActiveCard: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 11) {
                Image(systemName: "ticket.fill")
                    .foregroundStyle(Theme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("У вас активен промо-доступ")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(settings.promoDaysLeft.map { "Осталось \(pluralRu($0, "день", "дня", "дней"))" }
                         ?? "Все функции открыты бессрочно")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
        }
    }

    private var disclaimer: some View {
        VStack(spacing: 6) {
            Text("Бесплатная версия остаётся доступной: базовые конспекты и выжимки с показом рекламы.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Text("Подписка продлевается автоматически, если не отменить её не позднее чем за 24 часа до конца оплаченного периода. Управлять подпиской и отключать продление можно в настройках Apple ID.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
                .multilineTextAlignment(.center)
        }
    }
}

#Preview {
    PaywallView()
        .environment(AppSettings.shared)
}
