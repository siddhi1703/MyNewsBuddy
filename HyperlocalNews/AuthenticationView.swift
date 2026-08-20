import Combine
import AuthenticationServices
import SwiftUI

struct ContentView: View {
    @StateObject private var authentication = AuthenticationViewModel()

    var body: some View {
        Group {
            switch authentication.state {
            case .signedOut:
                AuthenticationLandingView(model: authentication)
            case .awaitingVerification(let email):
                OTPVerificationView(email: email, model: authentication)
            case .requestingPasswordReset(let email):
                PasswordResetRequestView(initialEmail: email, model: authentication)
            case .awaitingPasswordReset(let email):
                PasswordResetVerificationView(email: email, model: authentication)
            case .authenticated:
                MainAppView(
                    accountEmail: authentication.accountEmail,
                    accountDisplayName: authentication.accountDisplayName
                ) {
                    Task {
                        await authentication.signOut()
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: authentication.transitionID)
        .task {
            await authentication.restoreSession()
        }
    }
}

private enum AuthenticationState {
    case signedOut
    case awaitingVerification(email: String)
    case requestingPasswordReset(email: String)
    case awaitingPasswordReset(email: String)
    case authenticated
}

@MainActor
private final class AuthenticationViewModel: ObservableObject {
    @Published private(set) var state = AuthenticationState.signedOut
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published private(set) var accountEmail: String?
    @Published private(set) var accountDisplayName: String?

    private let service = SupabaseAuthService()
    private let googleWebSession = GoogleWebAuthenticationSession()
    private var didAttemptRestore = false

    var transitionID: String {
        switch state {
        case .signedOut: "signed-out"
        case .awaitingVerification: "verification"
        case .requestingPasswordReset: "password-reset-request"
        case .awaitingPasswordReset: "password-reset-verification"
        case .authenticated: "authenticated"
        }
    }

    func restoreSession() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        guard await service.hasStoredSession() else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            try await service.restoreSession()
            accountEmail = await service.storedEmail()
            accountDisplayName = await service.storedDisplayName()
            state = .authenticated
        } catch {
            await service.clearSession()
            state = .signedOut
        }
    }

    func signIn(email: String, password: String) async {
        resetMessages()
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard isValidEmail(normalizedEmail) else {
            errorMessage = "Enter a valid email address."
            return
        }
        guard !password.isEmpty else {
            errorMessage = "Enter your password."
            return
        }

        await perform {
            try await service.signIn(email: normalizedEmail, password: password)
            accountEmail = normalizedEmail
            accountDisplayName = await service.storedDisplayName()
            state = .authenticated
        }
    }

    func signInWithGoogle() async {
        resetMessages()
        isLoading = true
        defer { isLoading = false }

        do {
            let authorizationURL = try await service.googleOAuthURL()
            let callbackURL = try await googleWebSession.authenticate(url: authorizationURL)
            accountEmail = try await service.completeGoogleSignIn(callbackURL: callbackURL)
            accountDisplayName = await service.storedDisplayName()
            state = .authenticated
        } catch let error as ASWebAuthenticationSessionError
                    where error.code == .canceledLogin {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Google sign-in could not be completed."
        }
    }

    func startPasswordRecovery(email: String) {
        resetMessages()
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        state = .requestingPasswordReset(email: normalizedEmail)
    }

    func sendPasswordRecovery(email: String) async {
        resetMessages()
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard isValidEmail(normalizedEmail) else {
            errorMessage = "Enter a valid email address."
            return
        }

        await perform {
            try await service.requestPasswordReset(email: normalizedEmail)
            noticeMessage = "A password recovery code was sent to \(normalizedEmail)."
            state = .awaitingPasswordReset(email: normalizedEmail)
        }
    }

    func resendPasswordRecovery(email: String) async {
        resetMessages()
        await perform {
            try await service.requestPasswordReset(email: email)
            noticeMessage = "A new password recovery code was sent to \(email)."
        }
    }

    func completePasswordRecovery(
        email: String,
        code: String,
        password: String,
        confirmPassword: String
    ) async {
        resetMessages()
        let normalizedCode = code.filter(\.isNumber)

        guard (6...10).contains(normalizedCode.count) else {
            errorMessage = "Enter the complete recovery code from your email."
            return
        }
        guard password.count >= 8,
              password.contains(where: \.isUppercase),
              password.contains(where: \.isLowercase),
              password.contains(where: \.isNumber) else {
            errorMessage = "Use at least 8 characters with an uppercase letter, lowercase letter, and number."
            return
        }
        guard password == confirmPassword else {
            errorMessage = "The passwords do not match."
            return
        }

        await perform {
            try await service.verifyPasswordRecovery(email: email, token: normalizedCode)
            try await service.updatePassword(password)
            accountEmail = email
            accountDisplayName = await service.storedDisplayName()
            state = .authenticated
        }
    }

    func cancelPasswordRecovery() {
        resetMessages()
        state = .signedOut
    }

    func signUp(
        displayName: String,
        email: String,
        phone: String,
        password: String,
        confirmPassword: String
    ) async {
        resetMessages()
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPhone = phone.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")

        guard normalizedName.count >= 2 else {
            errorMessage = "Enter your name."
            return
        }
        guard isValidEmail(normalizedEmail) else {
            errorMessage = "Enter a valid email address."
            return
        }
        guard normalizedPhone.hasPrefix("+"),
              normalizedPhone.dropFirst().allSatisfy(\.isNumber),
              (8...15).contains(normalizedPhone.dropFirst().count) else {
            errorMessage = "Enter your phone number with country code, for example +16175550123."
            return
        }
        guard password.count >= 8,
              password.contains(where: \.isUppercase),
              password.contains(where: \.isLowercase),
              password.contains(where: \.isNumber) else {
            errorMessage = "Use at least 8 characters with an uppercase letter, lowercase letter, and number."
            return
        }
        guard password == confirmPassword else {
            errorMessage = "The passwords do not match."
            return
        }

        await perform {
            try await service.signUp(
                email: normalizedEmail,
                phone: normalizedPhone,
                password: password,
                displayName: normalizedName
            )
            state = .awaitingVerification(email: normalizedEmail)
        }
    }

    func verifyOTP(email: String, code: String) async {
        resetMessages()
        let normalizedCode = code.filter(\.isNumber)
        guard (6...10).contains(normalizedCode.count) else {
            errorMessage = "Enter the complete verification code from your email."
            return
        }

        await perform {
            try await service.verifySignup(email: email, token: normalizedCode)
            accountEmail = email
            accountDisplayName = await service.storedDisplayName()
            state = .authenticated
        }
    }

    func resendOTP(email: String) async {
        resetMessages()

        await perform {
            try await service.resendSignupOTP(email: email)
            noticeMessage = "A new verification code was sent to \(email)."
        }
    }

    func cancelVerification() {
        resetMessages()
        state = .signedOut
    }

    func signOut() async {
        isLoading = true
        await service.signOut()
        isLoading = false
        accountEmail = nil
        accountDisplayName = nil
        resetMessages()
        state = .signedOut
    }

    private func perform(_ operation: () async throws -> Void) async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await operation()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Something went wrong. Please try again."
        }
    }

    private func resetMessages() {
        errorMessage = nil
        noticeMessage = nil
    }

    private func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".")
    }
}

@MainActor
private final class GoogleWebAuthenticationSession: NSObject,
    ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "localcompanion"
            ) { [weak self] callbackURL, error in
                self?.session = nil
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: AuthenticationError.invalidResponse)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            guard session.start() else {
                self.session = nil
                continuation.resume(
                    throwing: AuthenticationError.server("Google sign-in could not be opened.")
                )
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
        return windowScene?.windows.first(where: \.isKeyWindow)
            ?? windowScene?.windows.first
            ?? ASPresentationAnchor()
    }
}

private enum AuthenticationMode: String, CaseIterable, Identifiable {
    case signIn = "Sign In"
    case signUp = "Sign Up"

    var id: String { rawValue }
}

private struct CountryDialCode: Identifiable, Hashable, Sendable {
    let regionCode: String
    let name: String
    let dialCode: String

    var id: String { regionCode }

    var flag: String {
        regionCode.unicodeScalars
            .compactMap { UnicodeScalar(127397 + $0.value) }
            .map(String.init)
            .joined()
    }

    static let options = [
        CountryDialCode(regionCode: "US", name: "United States", dialCode: "+1"),
        CountryDialCode(regionCode: "CA", name: "Canada", dialCode: "+1"),
        CountryDialCode(regionCode: "IN", name: "India", dialCode: "+91"),
        CountryDialCode(regionCode: "GB", name: "United Kingdom", dialCode: "+44"),
        CountryDialCode(regionCode: "AU", name: "Australia", dialCode: "+61"),
        CountryDialCode(regionCode: "NZ", name: "New Zealand", dialCode: "+64"),
        CountryDialCode(regionCode: "IE", name: "Ireland", dialCode: "+353"),
        CountryDialCode(regionCode: "DE", name: "Germany", dialCode: "+49"),
        CountryDialCode(regionCode: "FR", name: "France", dialCode: "+33"),
        CountryDialCode(regionCode: "IT", name: "Italy", dialCode: "+39"),
        CountryDialCode(regionCode: "ES", name: "Spain", dialCode: "+34"),
        CountryDialCode(regionCode: "MX", name: "Mexico", dialCode: "+52"),
        CountryDialCode(regionCode: "BR", name: "Brazil", dialCode: "+55"),
        CountryDialCode(regionCode: "AE", name: "United Arab Emirates", dialCode: "+971"),
        CountryDialCode(regionCode: "SG", name: "Singapore", dialCode: "+65"),
        CountryDialCode(regionCode: "JP", name: "Japan", dialCode: "+81"),
        CountryDialCode(regionCode: "KR", name: "South Korea", dialCode: "+82"),
        CountryDialCode(regionCode: "CN", name: "China", dialCode: "+86"),
        CountryDialCode(regionCode: "PK", name: "Pakistan", dialCode: "+92"),
        CountryDialCode(regionCode: "BD", name: "Bangladesh", dialCode: "+880"),
        CountryDialCode(regionCode: "NP", name: "Nepal", dialCode: "+977"),
        CountryDialCode(regionCode: "LK", name: "Sri Lanka", dialCode: "+94"),
        CountryDialCode(regionCode: "PH", name: "Philippines", dialCode: "+63"),
        CountryDialCode(regionCode: "MY", name: "Malaysia", dialCode: "+60"),
        CountryDialCode(regionCode: "ZA", name: "South Africa", dialCode: "+27"),
        CountryDialCode(regionCode: "NG", name: "Nigeria", dialCode: "+234"),
        CountryDialCode(regionCode: "KE", name: "Kenya", dialCode: "+254")
    ]

    static var regionalDefault: CountryDialCode {
        let currentRegion = Locale.current.region?.identifier ?? "US"
        return options.first(where: { $0.regionCode == currentRegion }) ?? options[0]
    }
}

private struct AuthenticationLandingView: View {
    @ObservedObject var model: AuthenticationViewModel

    @State private var mode = AuthenticationMode.signIn
    @State private var displayName = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var selectedCountry = CountryDialCode.regionalDefault
    @FocusState private var focusedField: Field?
    @Namespace private var modeIndicator

    private enum Field {
        case name
        case email
        case phone
        case password
        case confirmPassword
    }

    var body: some View {
        ZStack {
            authenticationBackground
                .onTapGesture {
                    focusedField = nil
                }

            ScrollView {
                VStack(spacing: 24) {
                    brand
                    formCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(keyboardActionTitle) {
                    advanceKeyboardFocus()
                }
                .fontWeight(.semibold)
            }
        }
    }

    private var authenticationBackground: some View {
        AnimatedAuthenticationBackground()
    }

    private var brand: some View {
        VStack(spacing: 13) {
            GlowingSunMark()

            Text("Local Companion")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.36))
                .multilineTextAlignment(.center)
                .shadow(color: .white.opacity(0.72), radius: 2, y: 2)

            Text("Trusted answers for your community")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(Color(red: 0.20, green: 0.24, blue: 0.46).opacity(0.82))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 20)
    }

    private var formCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 4) {
                ForEach(AuthenticationMode.allCases) { option in
                    Button {
                        focusedField = nil
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            mode = option
                        }
                    } label: {
                        Text(option.rawValue)
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(mode == option ? Color.primary : Color.primary.opacity(0.58))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background {
                                if mode == option {
                                    Capsule()
                                        .fill(.white.opacity(0.96))
                                        .matchedGeometryEffect(id: "selected-mode", in: modeIndicator)
                                        .shadow(color: .black.opacity(0.09), radius: 8, y: 3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(.white.opacity(0.24), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Account action")

            if !AppConfiguration.isSupabaseConfigured {
                configurationNotice
            }

            VStack(spacing: 13) {
                if mode == .signUp {
                    AuthTextField(
                        title: "Your name",
                        symbol: "person.fill",
                        text: $displayName,
                        contentType: .name,
                        keyboardType: .default,
                        isFocused: focusedField == .name
                    )
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .name)
                }

                AuthTextField(
                    title: "Email",
                    symbol: "envelope.fill",
                    text: $email,
                    contentType: .emailAddress,
                    keyboardType: .emailAddress,
                    isFocused: focusedField == .email
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)

                if mode == .signUp {
                    phoneNumberField
                }

                AuthSecureField(
                    title: "Password",
                    symbol: "lock.fill",
                    text: $password,
                    contentType: mode == .signUp ? .newPassword : .password,
                    isFocused: focusedField == .password
                )
                .focused($focusedField, equals: .password)
                .simultaneousGesture(TapGesture().onEnded {
                    focusedField = .password
                })

                if mode == .signIn {
                    Button("Forgot password?") {
                        focusedField = nil
                        model.startPasswordRecovery(email: email)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if mode == .signUp,
                   focusedField == .password || !password.isEmpty {
                    PasswordRequirementsView(password: password)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if mode == .signUp {
                    AuthSecureField(
                        title: "Confirm password",
                        symbol: "lock.shield.fill",
                        text: $confirmPassword,
                        contentType: .newPassword,
                        isFocused: focusedField == .confirmPassword
                    )
                    .focused($focusedField, equals: .confirmPassword)
                    .simultaneousGesture(TapGesture().onEnded {
                        focusedField = .confirmPassword
                    })

                    if !confirmPassword.isEmpty {
                        PasswordMatchView(matches: password == confirmPassword)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: focusedField)
            .animation(.easeInOut(duration: 0.2), value: password)

            StatusMessage(error: model.errorMessage, notice: model.noticeMessage)

            Button(action: submit) {
                Group {
                    if model.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(mode.rawValue)
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .padding(.vertical, 10)
            }
            .buttonStyle(WarmGradientButtonStyle())
            .disabled(model.isLoading)

            if mode == .signIn {
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                    Text("OR")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                }

                Button {
                    focusedField = nil
                    Task {
                        await model.signInWithGoogle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text("G")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
                        Text("Continue with Google")
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .padding(.vertical, 10)
                }
                .buttonStyle(GlassSecondaryButtonStyle())
                .disabled(model.isLoading)
            }

            if mode == .signUp {
                Text("By creating an account, you agree to receive the verification email required to activate it.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.58),
                                Color(red: 0.91, green: 0.87, blue: 1.0).opacity(0.28),
                                .white.opacity(0.34)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.62), .white.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: Color(red: 0.34, green: 0.42, blue: 0.70).opacity(0.18), radius: 28, y: 16)
    }

    private var configurationNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(.orange)
            Text("The account screens are ready. Add your Supabase project URL and publishable key to activate real email delivery.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var phoneNumberField: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Country code", selection: $selectedCountry) {
                    ForEach(CountryDialCode.options) { country in
                        Text("\(country.flag) \(country.name)  \(country.dialCode)")
                            .tag(country)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedCountry.flag)
                    Text(selectedCountry.dialCode)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 52)
                .background(.white.opacity(0.80), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(.white.opacity(0.38), lineWidth: 1)
                }
            }
            .accessibilityLabel("Country calling code")

            HStack(spacing: 10) {
                Image(systemName: "phone.fill")
                    .foregroundStyle(.secondary)

                TextField("Phone number", text: $phone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
                    .onChange(of: phone) {
                        let digits = String(phone.filter(\.isNumber).prefix(15))
                        if digits != phone {
                            phone = digits
                        }
                    }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(.white.opacity(0.80), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(
                        focusedField == .phone ? Color.orange.opacity(0.76) : .white.opacity(0.38),
                        lineWidth: focusedField == .phone ? 1.5 : 1
                    )
            }
            .shadow(color: focusedField == .phone ? .orange.opacity(0.12) : .clear, radius: 8)
        }
    }

    private var keyboardActionTitle: String {
        switch focusedField {
        case .name, .email, .phone:
            "Next"
        case .password where mode == .signUp:
            "Next"
        default:
            "Done"
        }
    }

    private func advanceKeyboardFocus() {
        switch focusedField {
        case .name:
            focusedField = .email
        case .email:
            focusedField = mode == .signUp ? .phone : .password
        case .phone:
            focusedField = .password
        case .password:
            focusedField = mode == .signUp ? .confirmPassword : nil
        default:
            focusedField = nil
        }
    }

    private func submit() {
        focusedField = nil
        Task {
            if mode == .signIn {
                await model.signIn(email: email, password: password)
            } else {
                let fullPhoneNumber = selectedCountry.dialCode + phone.filter(\.isNumber)
                await model.signUp(
                    displayName: displayName,
                    email: email,
                    phone: fullPhoneNumber,
                    password: password,
                    confirmPassword: confirmPassword
                )
            }
        }
    }
}

private struct AnimatedAuthenticationBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.62, green: 0.88, blue: 1.0),
                        Color(red: 0.72, green: 0.78, blue: 1.0),
                        Color(red: 0.86, green: 0.72, blue: 0.98),
                        Color(red: 1.0, green: 0.82, blue: 0.72)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                FloatingOrb(
                    colors: [.white.opacity(0.92), .cyan.opacity(0.08)],
                    diameter: 250
                )
                .position(x: proxy.size.width * 0.02, y: proxy.size.height * 0.20)
                .offset(x: isAnimating ? 38 : -18, y: isAnimating ? -20 : 28)

                FloatingOrb(
                    colors: [Color(red: 1.0, green: 0.58, blue: 0.72).opacity(0.50), .pink.opacity(0.05)],
                    diameter: 215
                )
                .position(x: proxy.size.width * 0.94, y: proxy.size.height * 0.38)
                .offset(x: isAnimating ? -26 : 18, y: isAnimating ? 28 : -30)

                FloatingOrb(
                    colors: [Color(red: 1.0, green: 0.78, blue: 0.38).opacity(0.52), .yellow.opacity(0.05)],
                    diameter: 285
                )
                .position(x: proxy.size.width * 0.45, y: proxy.size.height * 0.92)
                .offset(x: isAnimating ? 34 : -28, y: isAnimating ? -24 : 18)

                Circle()
                    .fill(.white.opacity(0.32))
                    .frame(width: 94, height: 94)
                    .blur(radius: 1)
                    .position(x: proxy.size.width * 0.82, y: proxy.size.height * 0.12)
                    .offset(y: isAnimating ? 18 : -14)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

private struct FloatingOrb: View {
    let colors: [Color]
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: colors,
                    center: .center,
                    startRadius: 2,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .blur(radius: 18)
            .accessibilityHidden(true)
    }
}

private struct GlowingSunMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isGlowing = false
    @State private var tapCount = 0

    var body: some View {
        Button {
            tapCount += 1
        } label: {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.38))
                    .frame(width: 130, height: 130)
                    .blur(radius: 22)
                    .scaleEffect(isGlowing ? 1.12 : 0.94)

                Circle()
                    .fill(.white.opacity(0.50))
                    .frame(width: 100, height: 100)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.78), lineWidth: 1.2)
                    }
                    .shadow(color: .white.opacity(0.55), radius: 12)

                Image(systemName: "sun.max.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.83, blue: 0.08), Color(red: 1.0, green: 0.45, blue: 0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: .orange.opacity(0.68), radius: 14)
                    .rotationEffect(.degrees(isGlowing ? 5 : -5))
                    .symbolEffect(.bounce, value: tapCount)
            }
        }
        .buttonStyle(SunButtonStyle())
        .frame(width: 132, height: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sunny weather companion")
        .accessibilityHint("Tap to animate the sun")
        .sensoryFeedback(.selection, trigger: tapCount)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                isGlowing = true
            }
        }
    }
}

private struct SunButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .rotationEffect(.degrees(configuration.isPressed ? -4 : 0))
            .animation(.spring(response: 0.25, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

private struct WarmGradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.60, blue: 0.18),
                        Color(red: 1.0, green: 0.28, blue: 0.56)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.30), lineWidth: 1)
            }
            .shadow(
                color: Color(red: 0.98, green: 0.28, blue: 0.55).opacity(isEnabled ? 0.34 : 0),
                radius: configuration.isPressed ? 7 : 14,
                y: configuration.isPressed ? 4 : 9
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct GlassSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.64 : 0.50), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.42), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.50)
            .animation(.spring(response: 0.24, dampingFraction: 0.74), value: configuration.isPressed)
    }
}

private struct PasswordResetRequestView: View {
    @ObservedObject var model: AuthenticationViewModel

    @State private var email: String
    @FocusState private var isEmailFocused: Bool

    init(initialEmail: String, model: AuthenticationViewModel) {
        self.model = model
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        ZStack {
            PasswordResetBackground()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 84, height: 84)
                    Image(systemName: "key.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.purple)
                }

                VStack(spacing: 7) {
                    Text("Reset your password")
                        .font(.title2.bold())
                    Text("Enter your account email and we’ll send you a secure recovery code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                AuthTextField(
                    title: "Email",
                    symbol: "envelope.fill",
                    text: $email,
                    contentType: .emailAddress,
                    keyboardType: .emailAddress
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isEmailFocused)

                StatusMessage(error: model.errorMessage, notice: model.noticeMessage)

                Button {
                    Task {
                        await model.sendPasswordRecovery(email: email)
                    }
                } label: {
                    Group {
                        if model.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Send Recovery Code")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(model.isLoading)

                Button("Back to Sign In") {
                    model.cancelPasswordRecovery()
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(24)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.16), radius: 24, y: 14)
            .padding()
            .frame(maxWidth: 540)
        }
        .task {
            isEmailFocused = email.isEmpty
        }
    }
}

private struct PasswordResetVerificationView: View {
    let email: String
    @ObservedObject var model: AuthenticationViewModel

    @State private var code = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case code
        case password
        case confirmPassword
    }

    var body: some View {
        ZStack {
            PasswordResetBackground()

            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 78, height: 78)
                        Image(systemName: "lock.rotation")
                            .font(.system(size: 34))
                            .foregroundStyle(.purple)
                    }

                    VStack(spacing: 6) {
                        Text("Create a new password")
                            .font(.title2.bold())
                        Text("Enter the recovery code sent to")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(email)
                            .font(.subheadline.weight(.semibold))
                    }
                    .multilineTextAlignment(.center)

                    TextField("Recovery code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .tracking(4)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .focused($focusedField, equals: .code)
                        .onChange(of: code) {
                            let filtered = String(code.filter(\.isNumber).prefix(10))
                            if filtered != code {
                                code = filtered
                            }
                        }

                    AuthSecureField(
                        title: "New password",
                        symbol: "lock.fill",
                        text: $password,
                        contentType: .newPassword
                    )
                    .focused($focusedField, equals: .password)
                    .simultaneousGesture(TapGesture().onEnded {
                        focusedField = .password
                    })

                    PasswordRequirementsView(password: password)

                    AuthSecureField(
                        title: "Confirm new password",
                        symbol: "lock.shield.fill",
                        text: $confirmPassword,
                        contentType: .newPassword
                    )
                    .focused($focusedField, equals: .confirmPassword)

                    if !confirmPassword.isEmpty {
                        PasswordMatchView(matches: password == confirmPassword)
                    }

                    StatusMessage(error: model.errorMessage, notice: model.noticeMessage)

                    Button {
                        focusedField = nil
                        Task {
                            await model.completePasswordRecovery(
                                email: email,
                                code: code,
                                password: password,
                                confirmPassword: confirmPassword
                            )
                        }
                    } label: {
                        Group {
                            if model.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Update Password")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(model.isLoading)

                    Button("Resend recovery code") {
                        Task {
                            await model.resendPasswordRecovery(email: email)
                        }
                    }
                    .disabled(model.isLoading)

                    Button("Cancel") {
                        model.cancelPasswordRecovery()
                    }
                    .font(.footnote)
                }
                .padding(24)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .shadow(color: .black.opacity(0.16), radius: 24, y: 14)
                .padding()
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .task {
            focusedField = .code
        }
    }
}

private struct PasswordResetBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.42, green: 0.77, blue: 1.0),
                Color(red: 0.56, green: 0.39, blue: 0.91)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct OTPVerificationView: View {
    let email: String
    @ObservedObject var model: AuthenticationViewModel

    @State private var code = ""
    @FocusState private var isCodeFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.42, green: 0.77, blue: 1.0),
                    Color(red: 0.56, green: 0.39, blue: 0.91)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 88, height: 88)
                    Image(systemName: "envelope.badge.shield.half.filled.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.purple)
                }

                VStack(spacing: 8) {
                    Text("Verify your email")
                        .font(.title.bold())
                    Text("Enter the verification code sent to")
                        .foregroundStyle(.secondary)
                    Text(email)
                        .font(.subheadline.bold())
                }
                .multilineTextAlignment(.center)

                TextField("Verification code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .tracking(5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .focused($isCodeFocused)
                    .onChange(of: code) {
                        let filtered = String(code.filter(\.isNumber).prefix(10))
                        if filtered != code {
                            code = filtered
                        }
                    }

                StatusMessage(error: model.errorMessage, notice: model.noticeMessage)

                Button {
                    Task {
                        await model.verifyOTP(email: email, code: code)
                    }
                } label: {
                    Group {
                        if model.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Verify and Continue")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(model.isLoading || !(6...10).contains(code.count))

                Button("Resend code") {
                    Task {
                        await model.resendOTP(email: email)
                    }
                }
                .disabled(model.isLoading)

                Button("Use a different email") {
                    model.cancelVerification()
                }
                .font(.footnote)
            }
            .padding(24)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.16), radius: 24, y: 14)
            .padding()
            .frame(maxWidth: 540)
        }
        .task {
            isCodeFocused = true
        }
    }
}

private struct AuthTextField: View {
    let title: String
    let symbol: String
    @Binding var text: String
    let contentType: UITextContentType?
    let keyboardType: UIKeyboardType
    var isFocused = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            TextField(title, text: $text)
                .textContentType(contentType)
                .keyboardType(keyboardType)
        }
        .padding(14)
        .background(.white.opacity(isFocused ? 0.92 : 0.80), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(
                    isFocused ? Color.orange.opacity(0.76) : .white.opacity(0.38),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .shadow(color: isFocused ? .orange.opacity(0.12) : .clear, radius: 8)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct AuthSecureField: View {
    let title: String
    let symbol: String
    @Binding var text: String
    let contentType: UITextContentType?
    var isFocused = false

    @State private var isTextVisible = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Group {
                if isTextVisible {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Button {
                isTextVisible.toggle()
            } label: {
                Image(systemName: isTextVisible ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isTextVisible ? "Hide password" : "Show password")
        }
        .padding(14)
        .background(.white.opacity(isFocused ? 0.92 : 0.80), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(
                    isFocused ? Color.orange.opacity(0.76) : .white.opacity(0.38),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .shadow(color: isFocused ? .orange.opacity(0.12) : .clear, radius: 8)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct PasswordRequirementsView: View {
    let password: String

    private var requirements: [(text: String, isMet: Bool)] {
        [
            ("At least 8 characters", password.count >= 8),
            ("One uppercase letter", password.contains(where: \.isUppercase)),
            ("One lowercase letter", password.contains(where: \.isLowercase)),
            ("One number", password.contains(where: \.isNumber))
        ]
    }

    private var allRequirementsMet: Bool {
        requirements.allSatisfy(\.isMet)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Password requirements")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            ForEach(Array(requirements.enumerated()), id: \.offset) { _, requirement in
                Label {
                    Text(requirement.text)
                } icon: {
                    Image(systemName: requirement.isMet ? "checkmark.circle.fill" : "xmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(requirement.isMet ? .green : .red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            (allRequirementsMet ? Color.green : Color.red).opacity(0.07),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(
                    (allRequirementsMet ? Color.green : Color.red).opacity(0.22),
                    lineWidth: 1
                )
        }
    }
}

private struct PasswordMatchView: View {
    let matches: Bool

    var body: some View {
        Label(
            matches ? "Passwords match" : "Passwords do not match",
            systemImage: matches ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
        .font(.caption)
        .foregroundStyle(matches ? .green : .red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

private struct StatusMessage: View {
    let error: String?
    let notice: String?

    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
