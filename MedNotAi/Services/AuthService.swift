import Foundation
import AuthenticationServices
import CryptoKit
import SwiftUI

// MARK: - Модель пользователя

enum AuthProvider: String, Codable, Sendable {
    case apple, google

    var title: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        }
    }
}

/// Профиль вошедшего пользователя. Лежит в Keychain, а не в UserDefaults:
/// почта и идентификатор — персональные данные.
struct AuthProfile: Codable, Equatable, Sendable {
    var provider: AuthProvider
    /// Стабильный идентификатор от провайдера (Apple `user`, Google `sub`).
    var subject: String
    var email: String?
    var fullName: String?
    var signedInAt: Date

    var displayName: String {
        if let fullName, !fullName.isEmpty { return fullName }
        if let email, let name = email.split(separator: "@").first { return String(name) }
        return "Пользователь"
    }
}

enum AuthError: LocalizedError, Equatable {
    case cancelled
    case googleNotConfigured
    case invalidResponse
    case tokenExchangeFailed(String)
    case identityMismatch
    case revoked

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Вход отменён."
        case .googleNotConfigured:
            "Вход через Google не настроен: в сборку не добавлен идентификатор OAuth-клиента."
        case .invalidResponse:
            "Провайдер вернул неполные данные. Попробуйте войти ещё раз."
        case .tokenExchangeFailed(let detail):
            "Не удалось завершить вход: \(detail)"
        case .identityMismatch:
            "Ответ провайдера не прошёл проверку подлинности. Вход отменён в целях безопасности."
        case .revoked:
            "Доступ к аккаунту отозван. Войдите заново."
        }
    }
}

// MARK: - Сервис

/// Вход через Apple и Google.
///
/// У приложения нет собственного сервера, поэтому вход решает две задачи:
/// подтверждает личность и даёт стабильный идентификатор, к которому
/// привязаны локальные данные. Синхронизации между устройствами он не даёт —
/// для неё понадобился бы бэкенд.
///
/// Что сделано для безопасности:
/// * одноразовый `nonce` в запросе к Apple и Google — перехваченный ответ
///   нельзя переиграть повторно;
/// * PKCE (S256) для Google вместо клиентского секрета: секрет в мобильном
///   приложении всё равно извлекается из бинарника, PKCE эту проблему снимает;
/// * параметр `state` защищает от подмены ответа;
/// * токены и профиль лежат в Keychain с `ThisDeviceOnly`;
/// * при каждом запуске проверяется, не отозван ли доступ Apple ID.
@Observable
final class AuthService: NSObject {
    static let shared = AuthService()

    private(set) var profile: AuthProfile?
    private(set) var isBusy = false
    var lastError: String?

    /// Пользователь прошёл вход через провайдера.
    var isSignedIn: Bool { profile != nil }

    /// Настроен ли вход через Google в этой сборке.
    var isGoogleAvailable: Bool { GoogleOAuth.clientID != nil }

    /// Сырой nonce последнего запроса к Apple — сверяем с ответом.
    private var currentNonce: String?
    /// Сессию нужно держать, пока открыто окно входа: иначе система
    /// отменяет её при освобождении локальной переменной.
    private var webAuthSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
        profile = Keychain.decode(AuthProfile.self, from: .authProfile)
    }

    // MARK: - Apple

    /// Готовит запрос для `SignInWithAppleButton`. Apple получает хеш nonce,
    /// а сырое значение остаётся у нас и сверяется с ответным id_token.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled {
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                lastError = AuthError.invalidResponse.localizedDescription
                return
            }
            do {
                try acceptAppleCredential(credential)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func acceptAppleCredential(_ credential: ASAuthorizationAppleIDCredential) throws {
        // Без совпадения nonce вход не принимаем: иначе можно подставить
        // чужой identity token. Apple кладёт в JWT тот же хеш, что ушёл в запросе.
        let expectedNonce = currentNonce
        currentNonce = nil
        guard let expectedNonce,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              let claims = JWT.claims(token),
              claims["nonce"] as? String == Self.sha256(expectedNonce) else {
            throw AuthError.identityMismatch
        }

        // Имя и почту Apple присылает только при самом первом входе,
        // поэтому уже сохранённые значения не затираем.
        let previous = profile?.subject == credential.user ? profile : nil
        let name = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        store(AuthProfile(
            provider: .apple,
            subject: credential.user,
            email: credential.email ?? previous?.email,
            fullName: name.isEmpty ? previous?.fullName : name,
            signedInAt: Date()
        ))
        Keychain.set(credential.user, for: .appleUserID)
    }

    /// Apple ID мог быть отвязан в системных настройках — проверяем при запуске.
    func refreshAppleCredentialState() async {
        guard profile?.provider == .apple, let userID = Keychain.string(.appleUserID) else { return }
        let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID)
        if state == .revoked || state == .notFound {
            signOut()
            lastError = AuthError.revoked.localizedDescription
        }
    }

    // MARK: - Google

    func signInWithGoogle() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let profile = try await GoogleOAuth.signIn(presentationProvider: self, sessionSink: { [weak self] session in
                self?.webAuthSession = session
            })
            webAuthSession = nil
            store(profile)
        } catch AuthError.cancelled {
            webAuthSession = nil
        } catch {
            webAuthSession = nil
            lastError = error.localizedDescription
        }
    }

    // MARK: - Выход

    func signOut() {
        profile = nil
        Keychain.remove(.authProfile)
        Keychain.remove(.appleUserID)
        Keychain.remove(.googleRefreshToken)
    }

    // MARK: - Внутреннее

    private func store(_ profile: AuthProfile) {
        self.profile = profile
        Keychain.encode(profile, to: .authProfile)
        lastError = nil

        // Подставляем имя в профиль приложения, если пользователь его ещё не заполнил.
        let settings = AppSettings.shared
        if settings.userName.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.userName = profile.displayName
        }
    }

    nonisolated static func randomNonceString(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
            bytes = (0..<length).map { _ in UInt8.random(in: 0...UInt8.max) }
        }
        return Data(bytes).base64URLEncodedString()
    }

    nonisolated static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Окно для веб-формы Google

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #else
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

// MARK: - OAuth 2.0 + PKCE для Google

/// Поток Authorization Code + PKCE — то, что Google предписывает нативным
/// приложениям. Клиентского секрета здесь нет и быть не должно: в приложении
/// его невозможно спрятать, а PKCE делает его ненужным.
///
/// Чтобы включить вход, создайте OAuth-клиент типа «iOS» в Google Cloud Console
/// и пропишите его идентификатор в настройке сборки `INFOPLIST_KEY_GoogleClientID`
/// (или в Info.plist ключом `GoogleClientID`). Пока ключа нет, кнопка входа
/// через Google не показывается.
enum GoogleOAuth {

    static var clientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    /// Google требует, чтобы адрес возврата был идентификатором клиента задом наперёд.
    private static func redirectScheme(for clientID: String) -> String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    private static let authorizeEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    static func signIn(presentationProvider: ASWebAuthenticationPresentationContextProviding,
                       sessionSink: @escaping @MainActor (ASWebAuthenticationSession) -> Void) async throws -> AuthProfile {
        guard let clientID else { throw AuthError.googleNotConfigured }

        let scheme = redirectScheme(for: clientID)
        let redirectURI = "\(scheme):/oauth2redirect"
        let verifier = AuthService.randomNonceString(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = AuthService.randomNonceString(length: 16)
        let nonce = AuthService.randomNonceString(length: 16)

        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce)
        ]

        let callback = try await present(url: components.url!, scheme: scheme, provider: presentationProvider, sessionSink: sessionSink)

        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw AuthError.invalidResponse
        }
        // Ответ обязан вернуть тот же state — иначе это подставной редирект.
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw AuthError.identityMismatch
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? AuthError.cancelled : AuthError.tokenExchangeFailed(error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.invalidResponse
        }

        return try await exchange(code: code, verifier: verifier, clientID: clientID,
                                  redirectURI: redirectURI, nonce: nonce)
    }

    private static func present(url: URL,
                                scheme: String,
                                provider: ASWebAuthenticationPresentationContextProviding,
                                sessionSink: @escaping @MainActor (ASWebAuthenticationSession) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? AuthError.invalidResponse)
                }
            }
            session.presentationContextProvider = provider
            // Не переиспользуем куки Safari: чужая активная сессия Google
            // не должна молча войти в приложение.
            session.prefersEphemeralWebBrowserSession = true
            Task { @MainActor in
                sessionSink(session)
                _ = session.start()
            }
        }
    }

    private static func exchange(code: String,
                                 verifier: String,
                                 clientID: String,
                                 redirectURI: String,
                                 nonce: String) async throws -> AuthProfile {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var form = URLComponents()
        form.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "code", value: code),
            .init(name: "code_verifier", value: verifier),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "redirect_uri", value: redirectURI)
        ]
        request.httpBody = form.percentEncodedQuery.map { Data($0.utf8) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AuthError.tokenExchangeFailed("HTTP \(code)")
        }

        struct TokenResponse: Decodable {
            let id_token: String?
            let refresh_token: String?
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let idToken = token.id_token, let claims = JWT.claims(idToken) else {
            throw AuthError.invalidResponse
        }

        // Токен пришёл напрямую от Google по TLS, поэтому подпись здесь не проверяем,
        // но сверяем адресата, издателя, срок и nonce — это ловит переигранный ответ.
        guard claims["aud"] as? String == clientID,
              (claims["iss"] as? String).map({ $0 == "https://accounts.google.com" || $0 == "accounts.google.com" }) == true,
              claims["nonce"] as? String == nonce,
              let subject = claims["sub"] as? String else {
            throw AuthError.identityMismatch
        }
        if let expiry = claims["exp"] as? TimeInterval, Date().timeIntervalSince1970 > expiry {
            throw AuthError.identityMismatch
        }

        Keychain.set(token.refresh_token, for: .googleRefreshToken)

        return AuthProfile(
            provider: .google,
            subject: subject,
            email: claims["email"] as? String,
            fullName: claims["name"] as? String,
            signedInAt: Date()
        )
    }
}

// MARK: - Разбор JWT

/// Читает полезную нагрузку id_token. Подпись не проверяется: без сервера
/// это делать негде, а токен и так получен напрямую от провайдера по TLS.
enum JWT {
    nonisolated static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }
}

// MARK: - base64url

extension Data {
    nonisolated func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated init?(base64URLEncoded string: String) {
        var value = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value.append("=") }
        self.init(base64Encoded: value)
    }
}
