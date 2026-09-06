import SwiftUI
import AuthenticationServices

/// Вход через Apple или Google.
///
/// Вход не обязателен: у приложения нет сервера, все конспекты и так лежат
/// на устройстве. Аккаунт нужен, чтобы подтвердить личность и заранее
/// подготовить почву для синхронизации, поэтому кнопка «продолжить без входа»
/// остаётся на видном месте, а не прячется мелким шрифтом.
struct SignInView: View {
    /// Показывается как шаг онбординга (со ссылкой «Продолжить без входа»)
    /// или как отдельный экран из профиля.
    var isOnboardingStep: Bool = false
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var auth = AuthService.shared

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 22) {
                    header
                    providerButtons
                    if let error = auth.lastError { errorBanner(error) }
                    privacyCard
                    if isOnboardingStep { skipButton }
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, isOnboardingStep ? 40 : 12)
                .readableWidth(460)
            }
        }
        .navigationTitle(isOnboardingStep ? "" : "Вход в аккаунт")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { onDone() }
        }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(spacing: 14) {
            GradientIcon(systemName: "person.badge.shield.checkmark.fill", size: 88)
            Text("Вход в MedNoteAi")
                .font(.title.bold())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Подтвердите личность через Apple или Google — это защитит доступ к вашим конспектам и подписке.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Кнопки провайдеров

    @ViewBuilder
    private var providerButtons: some View {
        VStack(spacing: 12) {
            SignInWithAppleButton(.signIn) { request in
                auth.prepareAppleRequest(request)
            } onCompletion: { result in
                auth.completeAppleSignIn(result)
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("Войти через Apple")

            if auth.isGoogleAvailable {
                Button {
                    Task { await auth.signInWithGoogle() }
                } label: {
                    HStack(spacing: 10) {
                        if auth.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "g.circle.fill")
                                .font(.title3)
                        }
                        Text("Войти через Google")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundStyle(Theme.textPrimary)
                    .background(Theme.cardFill(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(auth.isBusy)
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Что происходит с данными

    private var privacyCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 11) {
                Text("Что мы получаем")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                privacyRow("lock.fill", "Только идентификатор и почта",
                           "Пароль остаётся у Apple и Google — приложение его не видит и не хранит.")
                privacyRow("iphone", "Данные не покидают устройство",
                           "Конспекты, карточки и диалоги хранятся локально: у приложения нет собственного сервера.")
                privacyRow("eye.slash.fill", "Скрыть почту от Apple",
                           "Можно войти с функцией «Скрыть e-mail» — приложение будет работать так же.")
                privacyRow("key.fill", "Хранение в Keychain",
                           "Идентификатор входа лежит в системном хранилище и не попадает в резервные копии.")
            }
        }
    }

    private func privacyRow(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Theme.primary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var skipButton: some View {
        Button("Продолжить без входа") { onDone() }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.textSecondary)
    }
}

#Preview {
    SignInView(isOnboardingStep: true)
        .environment(AppSettings.shared)
}
