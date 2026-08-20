import Foundation
import Security

enum AuthenticationError: LocalizedError {
    case notConfigured
    case invalidResponse
    case accountAlreadyExists
    case server(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Connect a Supabase project before using real accounts."
        case .invalidResponse:
            "The authentication service returned an invalid response."
        case .accountAlreadyExists:
            "You already have an account with this email. Choose Sign In instead."
        case .server(let message):
            message
        case .keychain:
            "The secure session could not be saved on this device."
        }
    }
}

actor SupabaseAuthService {
    func hasStoredSession() -> Bool {
        SessionStore.read(.refreshToken) != nil
    }

    func storedEmail() -> String? {
        SessionStore.read(.email)
    }

    func storedDisplayName() -> String? {
        SessionStore.read(.displayName)
    }

    func currentAccessToken() -> String? {
        SessionStore.read(.accessToken)
    }

    func signUp(email: String, phone: String, password: String, displayName: String) async throws {
        let body = SignUpRequest(
            email: email,
            password: password,
            data: SignUpMetadata(phone: phone, fullName: displayName)
        )

        let data: Data
        do {
            data = try await send(
                path: "auth/v1/signup",
                body: try JSONEncoder().encode(body)
            )
        } catch AuthenticationError.server(let message)
                    where message.localizedCaseInsensitiveContains("already registered") {
            throw AuthenticationError.accountAlreadyExists
        }

        if let response = try? JSONDecoder().decode(SignUpResponse.self, from: data),
           response.identities?.isEmpty == true {
            throw AuthenticationError.accountAlreadyExists
        }

        // Email confirmation normally returns no session. If project settings return
        // one, store it safely and let verification still be enforced by the UI.
        if let session = try? JSONDecoder().decode(SessionResponse.self, from: data),
           !session.accessToken.isEmpty,
           !session.refreshToken.isEmpty {
            try SessionStore.save(session)
        }
    }

    func verifySignup(email: String, token: String) async throws {
        let body = VerifyOTPRequest(email: email, token: token, type: "signup")
        let data = try await send(
            path: "auth/v1/verify",
            body: try JSONEncoder().encode(body)
        )
        let session = try decodeSession(from: data)
        try SessionStore.save(session)
        try saveIdentity(session.user, fallbackEmail: email)
    }

    func resendSignupOTP(email: String) async throws {
        let body = ResendOTPRequest(email: email, type: "signup")
        _ = try await send(
            path: "auth/v1/resend",
            body: try JSONEncoder().encode(body)
        )
    }

    func signIn(email: String, password: String) async throws {
        let body = PasswordRequest(email: email, password: password)
        let data = try await send(
            path: "auth/v1/token",
            queryItems: [URLQueryItem(name: "grant_type", value: "password")],
            body: try JSONEncoder().encode(body)
        )
        let session = try decodeSession(from: data)
        try SessionStore.save(session)
        try saveIdentity(session.user, fallbackEmail: email)
    }

    func requestPasswordReset(email: String) async throws {
        let body = PasswordRecoveryRequest(email: email)
        _ = try await send(
            path: "auth/v1/recover",
            body: try JSONEncoder().encode(body)
        )
    }

    func verifyPasswordRecovery(email: String, token: String) async throws {
        let body = VerifyOTPRequest(email: email, token: token, type: "recovery")
        let data = try await send(
            path: "auth/v1/verify",
            body: try JSONEncoder().encode(body)
        )
        let session = try decodeSession(from: data)
        try SessionStore.save(session)
        try saveIdentity(session.user, fallbackEmail: email)
    }

    func updatePassword(_ password: String) async throws {
        guard let accessToken = SessionStore.read(.accessToken) else {
            throw AuthenticationError.server("Verify the recovery code before changing your password.")
        }

        let body = PasswordUpdateRequest(password: password)
        _ = try await send(
            path: "auth/v1/user",
            method: "PUT",
            bearerToken: accessToken,
            body: try JSONEncoder().encode(body)
        )
    }

    func googleOAuthURL() throws -> URL {
        let configuration = try AuthConfiguration.load()
        let endpoint = configuration.projectURL.appending(path: "auth/v1/authorize")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw AuthenticationError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: "localcompanion://auth-callback")
        ]
        guard let url = components.url else {
            throw AuthenticationError.invalidResponse
        }
        return url
    }

    func completeGoogleSignIn(callbackURL: URL) async throws -> String? {
        if let callbackError = oauthValue(named: "error_description", in: callbackURL) {
            throw AuthenticationError.server(callbackError.replacingOccurrences(of: "+", with: " "))
        }

        guard let accessToken = oauthValue(named: "access_token", in: callbackURL),
              let refreshToken = oauthValue(named: "refresh_token", in: callbackURL) else {
            throw AuthenticationError.invalidResponse
        }

        let session = SessionResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            user: nil
        )
        try SessionStore.save(session)

        let userData = try await send(
            path: "auth/v1/user",
            method: "GET",
            bearerToken: accessToken,
            body: nil
        )
        let user = try JSONDecoder().decode(CurrentUserResponse.self, from: userData)
        try saveIdentity(user)
        return user.email
    }

    func restoreSession() async throws {
        guard let refreshToken = SessionStore.read(.refreshToken) else {
            throw AuthenticationError.server("Your session has expired. Please sign in again.")
        }

        let body = RefreshRequest(refreshToken: refreshToken)
        let data = try await send(
            path: "auth/v1/token",
            queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: try JSONEncoder().encode(body)
        )
        let session = try decodeSession(from: data)
        try SessionStore.save(session)
        try saveIdentity(session.user)
    }

    func signOut() async {
        if let accessToken = SessionStore.read(.accessToken) {
            _ = try? await send(
                path: "auth/v1/logout",
                bearerToken: accessToken,
                body: nil
            )
        }
        SessionStore.clear()
    }

    func clearSession() {
        SessionStore.clear()
    }

    private func decodeSession(from data: Data) throws -> SessionResponse {
        do {
            let session = try JSONDecoder().decode(SessionResponse.self, from: data)
            guard !session.accessToken.isEmpty, !session.refreshToken.isEmpty else {
                throw AuthenticationError.invalidResponse
            }
            return session
        } catch let error as AuthenticationError {
            throw error
        } catch {
            throw AuthenticationError.invalidResponse
        }
    }

    private func saveIdentity(_ user: SessionUser?, fallbackEmail: String? = nil) throws {
        if let email = user?.email ?? fallbackEmail {
            try SessionStore.saveEmail(email)
        }
        if let displayName = user?.displayName {
            try SessionStore.saveDisplayName(displayName)
        }
    }

    private func saveIdentity(_ user: CurrentUserResponse) throws {
        if let email = user.email {
            try SessionStore.saveEmail(email)
        }
        if let displayName = user.displayName {
            try SessionStore.saveDisplayName(displayName)
        }
    }

    private func send(
        path: String,
        method: String = "POST",
        queryItems: [URLQueryItem] = [],
        bearerToken: String? = nil,
        body: Data?
    ) async throws -> Data {
        let configuration = try AuthConfiguration.load()
        let endpoint = configuration.projectURL.appending(path: path)

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw AuthenticationError.invalidResponse
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw AuthenticationError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthenticationError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(SupabaseErrorResponse.self, from: data)
            let message = apiError?.bestMessage
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw AuthenticationError.server(message)
        }

        return data
    }

    private func oauthValue(named name: String, in url: URL) -> String? {
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value {
            return value
        }

        guard let fragment = url.fragment,
              let components = URLComponents(string: "https://callback.local/?\(fragment)") else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }
}

enum InformationGapError: LocalizedError {
    case signedOut
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut:
            "Sign in again before saving this question."
        case .invalidResponse:
            "Supabase returned an invalid response."
        case .server(let message):
            message
        }
    }
}

actor InformationGapService {
    private let authentication = SupabaseAuthService()

    func logUnansweredQuestion(
        question: String,
        location: String,
        category: String,
        confidence: Double,
        evidenceChecked: [String],
        assistantResponse: String
    ) async throws -> UUID {
        let body = UnansweredQuestionRequest(
            question: question,
            location: location,
            category: category,
            status: "unanswered",
            notificationRequested: false,
            confidence: confidence,
            evidenceChecked: evidenceChecked,
            assistantResponse: assistantResponse
        )
        let data = try await request(
            method: "POST",
            body: try JSONEncoder().encode(body),
            preferRepresentation: true
        )

        guard let savedQuestion = try? JSONDecoder().decode([SavedQuestion].self, from: data).first else {
            throw InformationGapError.invalidResponse
        }
        return savedQuestion.id
    }

    func requestNotification(for questionID: UUID) async throws {
        let body = NotificationPreferenceRequest(notificationRequested: true)
        _ = try await request(
            method: "PATCH",
            queryItems: [URLQueryItem(name: "id", value: "eq.\(questionID.uuidString.lowercased())")],
            body: try JSONEncoder().encode(body),
            preferRepresentation: false
        )
    }

    private func request(
        method: String,
        queryItems: [URLQueryItem] = [],
        body: Data,
        preferRepresentation: Bool
    ) async throws -> Data {
        let configuration: AuthConfiguration
        do {
            configuration = try AuthConfiguration.load()
        } catch {
            throw InformationGapError.server(error.localizedDescription)
        }

        guard let accessToken = await authentication.currentAccessToken() else {
            throw InformationGapError.signedOut
        }

        let endpoint = configuration.projectURL.appending(path: "rest/v1/unanswered_questions")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw InformationGapError.invalidResponse
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw InformationGapError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            preferRepresentation ? "return=representation" : "return=minimal",
            forHTTPHeaderField: "Prefer"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw InformationGapError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(SupabaseErrorResponse.self, from: data)
            throw InformationGapError.server(
                apiError?.bestMessage
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
        return data
    }
}

private struct UnansweredQuestionRequest: Encodable {
    let question: String
    let location: String
    let category: String
    let status: String
    let notificationRequested: Bool
    let confidence: Double
    let evidenceChecked: [String]
    let assistantResponse: String

    enum CodingKeys: String, CodingKey {
        case question
        case location
        case category
        case status
        case notificationRequested = "notification_requested"
        case confidence
        case evidenceChecked = "evidence_checked"
        case assistantResponse = "assistant_response"
    }
}

private struct NotificationPreferenceRequest: Encodable {
    let notificationRequested: Bool

    enum CodingKeys: String, CodingKey {
        case notificationRequested = "notification_requested"
    }
}

private struct SavedQuestion: Decodable {
    let id: UUID
}

private struct SignUpRequest: Encodable {
    let email: String
    let password: String
    let data: SignUpMetadata
}

private struct SignUpResponse: Decodable {
    let identities: [SignUpIdentity]?
}

private struct SignUpIdentity: Decodable {
    let id: String?
}

private struct SignUpMetadata: Encodable {
    let phone: String
    let fullName: String

    enum CodingKeys: String, CodingKey {
        case phone
        case fullName = "full_name"
    }
}

private struct VerifyOTPRequest: Encodable {
    let email: String
    let token: String
    let type: String
}

private struct ResendOTPRequest: Encodable {
    let email: String
    let type: String
}

private struct PasswordRequest: Encodable {
    let email: String
    let password: String
}

private struct PasswordRecoveryRequest: Encodable {
    let email: String
}

private struct PasswordUpdateRequest: Encodable {
    let password: String
}

private struct RefreshRequest: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct SessionResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let user: SessionUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

private struct SessionUser: Decodable {
    let email: String?
    let userMetadata: UserMetadata?

    enum CodingKeys: String, CodingKey {
        case email
        case userMetadata = "user_metadata"
    }

    var displayName: String? {
        userMetadata?.displayName
    }
}

private struct CurrentUserResponse: Decodable {
    let email: String?
    let userMetadata: UserMetadata?

    enum CodingKeys: String, CodingKey {
        case email
        case userMetadata = "user_metadata"
    }

    var displayName: String? {
        userMetadata?.displayName
    }
}

private struct UserMetadata: Decodable {
    let fullName: String?
    let name: String?
    let givenName: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case name
        case givenName = "given_name"
    }

    var displayName: String? {
        [fullName, name, givenName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

private struct SupabaseErrorResponse: Decodable {
    let message: String?
    let msg: String?
    let errorDescription: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case message
        case msg
        case errorDescription = "error_description"
        case error
    }

    var bestMessage: String {
        message ?? msg ?? errorDescription ?? error ?? "Authentication failed."
    }
}

private enum SessionStore {
    enum Key: String {
        case accessToken = "auth.access-token"
        case refreshToken = "auth.refresh-token"
        case email = "auth.email"
        case displayName = "auth.display-name"
    }

    private static let service = "com.siddhikakani.HyperlocalNews"

    static func save(_ session: SessionResponse) throws {
        try save(session.accessToken, for: .accessToken)
        try save(session.refreshToken, for: .refreshToken)
    }

    static func saveEmail(_ email: String) throws {
        try save(email, for: .email)
    }

    static func saveDisplayName(_ displayName: String) throws {
        try save(displayName, for: .displayName)
    }

    static func read(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        for key in [Key.accessToken, Key.refreshToken, Key.email, Key.displayName] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key.rawValue
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func save(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else {
            throw AuthenticationError.invalidResponse
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw AuthenticationError.keychain(updateStatus)
        }

        var insertQuery = query
        attributes.forEach { insertQuery[$0.key] = $0.value }
        let insertStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw AuthenticationError.keychain(insertStatus)
        }
    }
}
