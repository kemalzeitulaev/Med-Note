import SwiftUI
import AuthenticationServices

/// Вход по почте, через Apple или Google.
///
/// На старте экран можно пропустить — тогда приложение откроется без сессии.
/// Войти позже можно из профиля. Пароль не пишется открытым текстом.
struct SignInView: View {
    var allowsSkip: Bool = false
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(AppSettings.self) private var settings
    @State private var auth = AuthService.shared
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field { case name, email, password }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(spacing: 22) {
                    header
                    providerButtons
                    if let error = auth.lastError { errorBanner(error) }
                    privacyCard
                    if allowsSkip { skipButton }
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, 40)
                .readableWidth(460)
            }
        }
        .navigationTitle("Вход в аккаунт")
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
            Text("Войдите или создайте аккаунт — тот же логин откроется на iPhone, iPad и Mac. Можно пропустить и войти позже.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Кнопки провайдеров

    @ViewBuilder
    private var providerButtons: some View {
        VStack(spacing: 12) {
            GlassCard(padding: 16) {
                VStack(spacing: 12) {
                    TextField("Имя", text: $name)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .name)
                    Divider().overlay(Theme.hairline)
                    TextField("Почта", text: $email)
                        .textFieldStyle(.plain)
                        .textContentType(.username)
                        .focused($focusedField, equals: .email)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Divider().overlay(Theme.hairline)
                    SecureField("Пароль: от 8 знаков, буква и цифра", text: $password)
                        .textFieldStyle(.plain)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                }
            }

            Button {
                focusedField = nil
                Task { await auth.signInWithEmail(name: name, email: email, password: password) }
            } label: {
                HStack {
                    if auth.isBusy { ProgressView().controlSize(.small).tint(.white) }
                    Text("Войти")
                }
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || auth.isBusy)

            Button {
                focusedField = nil
                Task { await auth.registerWithEmail(name: name, email: email, password: password) }
            } label: {
                Text("Создать аккаунт")
            }
            .buttonStyle(SoftButtonStyle(expands: true))
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || auth.isBusy)

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

                privacyRow("lock.fill", "Пароль не хранится открытым текстом",
                           "В iCloud уходит только соль и PBKDF2-хеш. Сам пароль устройство не отправляет.")
                privacyRow("icloud", "Один аккаунт на всех устройствах",
                           "Создали на iPhone — войдите той же почтой на iPad. На обоих устройствах должен быть включён iCloud.")
                privacyRow("iphone", "Конспекты едут вместе с аккаунтом",
                           "Заметки, фото, карточки, календарь, диалоги, голосовые лекции и группы синхронизируются через iCloud.")
                privacyRow("shield.lefthalf.filled", "Защита от перебора",
                           "После пяти неверных попыток вход блокируется на 15 минут.")
                privacyRow("key.fill", "Сессия отдельно от аккаунта",
                           "Выход закрывает сессию. Учётная запись остаётся, чтобы можно было войти снова.")
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
        Button("Продолжить без входа") {
            settings.hasSkippedSignIn = true
            onDone()
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Theme.textSecondary)
    }
}

#Preview {
    SignInView(allowsSkip: true)
        .environment(AppSettings.shared)
}
