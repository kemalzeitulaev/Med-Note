import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Ввод промокода. Проверка идёт локально, интернет не нужен.
struct PromoCodeView: View {
    var initialCode: String = ""

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var error: PromoCodeError?
    @State private var redeemed: PromoCode?
    @State private var showScanner = false
    @FocusState private var fieldFocused: Bool

    private var normalized: String { PromoCodeService.normalize(input) }
    private var isComplete: Bool { normalized.count == 20 }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        if let redeemed {
                            successCard(redeemed)
                        } else {
                            header
                            inputCard
                            if settings.tier == .promo { activeCard }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .readableWidth(480)
                }
            }
            .navigationTitle("Промокод")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(redeemed == nil ? "Закрыть" : "Готово") { dismiss() }
                }
            }
            .onAppear {
                if input.isEmpty, !initialCode.isEmpty {
                    input = PromoCodeService.format(initialCode)
                    apply()
                }
                fieldFocused = redeemed == nil && initialCode.isEmpty
            }
            #if os(iOS)
            .sheet(isPresented: $showScanner) {
                QRScannerView { scanned in
                    input = PromoCodeService.format(scanned)
                    // Сканирование сразу и активирует код: заставлять человека
                    // после наведения камеры жать ещё одну кнопку незачем.
                    apply()
                }
            }
            #endif
        }
    }

    // MARK: - Ввод

    private var header: some View {
        VStack(spacing: 11) {
            GradientIcon(systemName: "ticket.fill", size: 72)
            Text("Введите промокод")
                .font(.title3.bold())
                .foregroundStyle(Theme.textPrimary)
            Text("Промокод открывает полный доступ ко всем возможностям приложения без подписки и рекламы.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 6)
    }

    private var inputCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("XXXXX-XXXXX-XXXXX-XXXXX", text: $input)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    #endif
                    .onChange(of: input) { _, newValue in
                        error = nil
                        let clean = PromoCodeService.normalize(newValue)
                        let limited = String(clean.prefix(20))
                        let pretty = PromoCodeService.format(limited)
                        if pretty != newValue { input = pretty }
                    }
                    .onSubmit(apply)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Theme.surfaceTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let error {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Активировать", action: apply)
                    .buttonStyle(BrandButtonStyle())
                    .disabled(!isComplete)

                #if os(iOS)
                Button {
                    fieldFocused = false
                    showScanner = true
                } label: {
                    Label("Сканировать QR-код", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(SoftButtonStyle(expands: true))
                #endif

                Text("Регистр и дефисы не важны — код можно вводить как удобно.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var activeCard: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 11) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Промо-доступ уже активен")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(accessDescription)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
        }
    }

    private var accessDescription: String {
        if let days = settings.promoDaysLeft {
            return "Осталось \(pluralRu(days, "день", "дня", "дней"))"
        }
        return "Без ограничения по сроку"
    }

    // MARK: - Успех

    private func successCard(_ code: PromoCode) -> some View {
        VStack(spacing: 18) {
            GradientIcon(systemName: "checkmark.circle.fill", size: 84)
            VStack(spacing: 8) {
                Text("Код активирован")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text(code.benefit.title)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Text(code.benefit == .unlimited
                     ? "Полный доступ ко всем функциям открыт бессрочно. Реклама отключена."
                     : "Полный доступ открыт. Реклама отключена.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Отлично") { dismiss() }
                .buttonStyle(BrandButtonStyle())
        }
        .padding(.top, 30)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func apply() {
        switch settings.redeem(input) {
        case .success(let code):
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            fieldFocused = false
            withAnimation(.spring(duration: 0.4)) { redeemed = code }
        case .failure(let failure):
            withAnimation { error = failure }
        }
    }
}

#Preview {
    PromoCodeView()
        .environment(AppSettings.shared)
}
