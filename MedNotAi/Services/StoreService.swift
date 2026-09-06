import Foundation
import StoreKit
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Покупка подписки через App Store (StoreKit 2).
///
/// Почему не Apple Pay: правила App Store запрещают проводить оплату цифрового
/// контента и подписок мимо In-App Purchase (Guideline 3.1.1), а Apple Pay
/// предназначен для физических товаров и услуг вне приложения. При этом
/// пользователь всё равно платит привычной картой из Wallet — системное окно
/// подтверждения покупки использует Face ID / Touch ID ровно как Apple Pay.
///
/// Чек проверяется подписью App Store прямо на устройстве (`VerificationResult`).
/// Полноценная защита от подделки требует серверной проверки
/// в App Store Server API — здесь её заменяет локальная, чего достаточно,
/// пока подписка не открывает доступ к платным серверным ресурсам.
@Observable
final class StoreService {
    static let shared = StoreService()

    enum ProductID: String, CaseIterable {
        case monthly = "kemal.MedNotAi.premium.monthly"
        case yearly = "kemal.MedNotAi.premium.yearly"
    }

    enum PurchaseOutcome: Equatable {
        case purchased
        case pending
        case cancelled
    }

    private(set) var products: [Product] = []
    private(set) var purchasedProductIDs: Set<String> = []
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    /// Когда заканчивается оплаченный период. `nil` — подписки нет.
    private(set) var expirationDate: Date?
    var lastError: String?

    private var updatesTask: Task<Void, Never>?

    var hasActiveSubscription: Bool { !purchasedProductIDs.isEmpty }

    /// Товары в App Store Connect ещё не заведены или устройство офлайн.
    var isStoreUnavailable: Bool { products.isEmpty && !isLoading }

    var monthly: Product? { product(.monthly) }
    var yearly: Product? { product(.yearly) }

    private init() {
        // Слушаем обновления до загрузки товаров: сюда приходят покупки,
        // подтверждённые вне приложения, — «Запросить покупку», возвраты,
        // продление подписки и восстановление на другом устройстве.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self, let transaction = try? Self.verify(update) else { continue }
                await transaction.finish()
                await self.refreshEntitlements()
            }
        }
    }

    deinit { updatesTask?.cancel() }

    func product(_ id: ProductID) -> Product? {
        products.first { $0.id == id.rawValue }
    }

    // MARK: - Загрузка

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try await Product.products(for: ProductID.allCases.map(\.rawValue))
            // Годовой тариф показываем вторым, как в макете.
            products = loaded.sorted { $0.price < $1.price }
            lastError = nil
        } catch {
            products = []
            lastError = error.localizedDescription
        }
        await refreshEntitlements()
    }

    // MARK: - Покупка

    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        guard !isPurchasing else { return .cancelled }
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try Self.verify(verification)
                await transaction.finish()
                await refreshEntitlements()
                return .purchased
            case .pending:
                // Ждём одобрения — «Семейный доступ» или подтверждение банка.
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch {
            lastError = error.localizedDescription
            return .cancelled
        }
    }

    /// Восстановление покупок: обязательный пункт правил App Store.
    func restore() async {
        lastError = nil
        do {
            try await AppStore.sync()
        } catch {
            // Отмена в системном окне логина тоже прилетает ошибкой — не шумим.
            if case StoreKitError.userCancelled = error {} else {
                lastError = error.localizedDescription
            }
        }
        await refreshEntitlements()
    }

    /// Открывает системный экран управления подпиской.
    func manageSubscriptions() async {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        try? await AppStore.showManageSubscriptions(in: scene)
        #else
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: - Права доступа

    /// Пересобирает список действующих покупок и синхронизирует тариф приложения.
    func refreshEntitlements() async {
        var active: Set<String> = []
        var latestExpiry: Date?

        for await entitlement in Transaction.currentEntitlements {
            guard let transaction = try? Self.verify(entitlement) else { continue }
            guard transaction.revocationDate == nil else { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }

            active.insert(transaction.productID)
            if let expiry = transaction.expirationDate {
                latestExpiry = max(latestExpiry ?? expiry, expiry)
            }
        }

        purchasedProductIDs = active
        expirationDate = latestExpiry
        AppSettings.shared.applyStoreEntitlement(isActive: !active.isEmpty)
    }

    // MARK: - Проверка подписи

    private nonisolated static func verify<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            // Подпись не сошлась — покупку не засчитываем.
            throw error
        }
    }
}

extension Product {
    /// «$7 в месяц» — цена вместе с периодом, уже в валюте магазина.
    var localizedPeriodPrice: String {
        guard let period = subscription?.subscriptionPeriod else { return displayPrice }
        let suffix = switch period.unit {
        case .month: period.value == 1 ? "в месяц" : "за \(period.value) мес."
        case .year: period.value == 1 ? "в год" : "за \(period.value) г."
        case .week: "в неделю"
        case .day: "в день"
        @unknown default: ""
        }
        return suffix.isEmpty ? displayPrice : "\(displayPrice) \(suffix)"
    }

    /// Экономия годового тарифа относительно месячного, в процентах.
    func savingsPercent(comparedToMonthly monthly: Product) -> Int? {
        guard let period = subscription?.subscriptionPeriod, period.unit == .year else { return nil }
        let yearOfMonthly = monthly.price * 12
        guard yearOfMonthly > 0, price < yearOfMonthly else { return nil }
        let ratio = (yearOfMonthly - price) / yearOfMonthly
        return Int((ratio as NSDecimalNumber).doubleValue * 100)
    }

    /// Бесплатный пробный период, если он настроен у товара.
    var introductoryTrialDays: Int? {
        guard let offer = subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        let period = offer.period
        return switch period.unit {
        case .day: period.value
        case .week: period.value * 7
        case .month: period.value * 30
        case .year: period.value * 365
        @unknown default: nil
        }
    }
}
