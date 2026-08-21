import SwiftUI
import UIKit
import MapKit

struct MainAppView: View {
    let accountEmail: String?
    let accountDisplayName: String?
    let onSignOut: () -> Void

    @StateObject private var weatherModel = WeatherViewModel()
    @State private var selectedTab = AppTab.home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                model: weatherModel,
                selectedTab: $selectedTab,
                displayName: preferredFirstName
            )
                .tag(AppTab.home)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            ChatView(model: weatherModel)
                .tag(AppTab.chat)
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }

            TransitMapView(weatherModel: weatherModel)
            .tag(AppTab.timeline)
            .tabItem {
                Label("Map", systemImage: "map.fill")
            }

            PlannedFeatureView(
                title: "Events",
                message: "Local and university events are planned for the next data-source milestone.",
                symbol: "calendar",
                weather: weatherModel.weather
            )
            .tag(AppTab.events)
            .tabItem {
                Label("Events", systemImage: "calendar")
            }

            AccountProfileView(
                email: accountEmail,
                displayName: preferredDisplayName,
                weather: weatherModel.weather,
                onSignOut: onSignOut
            )
            .tag(AppTab.profile)
            .tabItem {
                Label("Profile", systemImage: "person.crop.circle.fill")
            }
        }
        .tint(Color(red: 0.34, green: 0.25, blue: 0.88))
        .task {
            weatherModel.start()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled else { break }
                weatherModel.refresh()
            }
        }
    }

    private var preferredDisplayName: String? {
        if let accountDisplayName = accountDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountDisplayName.isEmpty {
            return accountDisplayName
        }

        guard let localPart = accountEmail?.split(separator: "@").first else {
            return nil
        }
        let cleaned = localPart
            .replacingOccurrences(of: "[0-9]+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[._-]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned.capitalized
    }

    private var preferredFirstName: String? {
        preferredDisplayName?.split(separator: " ").first.map(String.init)
    }
}

private enum AppTab: Hashable {
    case home
    case chat
    case timeline
    case events
    case profile
}

private struct WeatherBackdrop: View {
    let condition: WeatherCondition
    var softened = false
    var softeningOpacity = 0.72

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: condition.colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: geometry.size.width * 1.05)
                    .blur(radius: 28)
                    .offset(
                        x: geometry.size.width * 0.42,
                        y: -geometry.size.height * 0.34
                    )

                Circle()
                    .fill(condition.accent.opacity(0.14))
                    .frame(width: geometry.size.width * 0.72)
                    .blur(radius: 34)
                    .offset(
                        x: -geometry.size.width * 0.36,
                        y: geometry.size.height * 0.35
                    )

                WeatherParticles(condition: condition)

                if softened {
                    Color(.systemBackground).opacity(softeningOpacity)
                }
            }
            .animation(.easeInOut(duration: 0.7), value: condition)
            .ignoresSafeArea()
        }
        .accessibilityHidden(true)
    }
}

private struct WeatherParticles: View {
    let condition: WeatherCondition

    var body: some View {
        GeometryReader { geometry in
            if condition == .rainy || condition == .stormy {
                ForEach(0..<18, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(0.17))
                        .frame(width: 2, height: CGFloat(18 + (index % 4) * 7))
                        .rotationEffect(.degrees(14))
                        .position(
                            x: geometry.size.width * CGFloat((index * 37) % 100) / 100,
                            y: geometry.size.height * CGFloat((index * 61) % 100) / 100
                        )
                }
            } else if condition == .snowy {
                ForEach(0..<20, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(0.44))
                        .frame(width: CGFloat(3 + index % 4), height: CGFloat(3 + index % 4))
                        .position(
                            x: geometry.size.width * CGFloat((index * 47) % 100) / 100,
                            y: geometry.size.height * CGFloat((index * 29) % 100) / 100
                        )
                }
            } else if condition == .night {
                ForEach(0..<16, id: \.self) { index in
                    Image(systemName: index.isMultiple(of: 3) ? "sparkle" : "circle.fill")
                        .font(.system(size: CGFloat(3 + index % 5)))
                        .foregroundStyle(.white.opacity(0.34))
                        .position(
                            x: geometry.size.width * CGFloat((index * 43) % 100) / 100,
                            y: geometry.size.height * CGFloat((index * 31) % 68) / 100
                        )
                }
            }
        }
    }
}

private struct WeatherMascot: View {
    let condition: WeatherCondition
    var size: CGFloat = 126
    var usesIllustration = false

    @State private var isFloating = false

    private var bundledIllustration: UIImage? {
        guard let url = Bundle.main.url(
            forResource: condition.mascotAssetName,
            withExtension: "png"
        ) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        Group {
            if usesIllustration, let bundledIllustration {
                Image(uiImage: bundledIllustration)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .id(condition)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
            } else {
                ZStack {
                    Circle()
                        .fill(condition.accent.opacity(0.22))
                        .frame(width: size, height: size)
                        .blur(radius: 1)

                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: size * 0.84, height: size * 0.84)
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.42), lineWidth: 1)
                        }

                    Image(systemName: condition.symbol)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .symbolRenderingMode(.multicolor)

                    Image(systemName: "sparkles")
                        .font(.system(size: size * 0.18, weight: .semibold))
                        .foregroundStyle(condition.accent)
                        .offset(x: size * 0.37, y: -size * 0.31)
                }
            }
        }
        .shadow(color: condition.accent.opacity(0.28), radius: 24, y: 12)
        .offset(y: isFloating ? -5 : 5)
        .rotationEffect(.degrees(isFloating ? 2 : -2))
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                isFloating = true
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.74), value: condition)
        .accessibilityLabel("\(condition.title) weather companion")
    }
}

private struct HomeView: View {
    @ObservedObject var model: WeatherViewModel
    @Binding var selectedTab: AppTab
    let displayName: String?
    @Environment(\.openURL) private var openURL
    @State private var isLocationPickerPresented = false

    private var weather: WeatherSnapshot {
        model.weather
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WeatherBackdrop(condition: weather.condition)

                ScrollView {
                    VStack(spacing: 18) {
                        topBar
                        heroCard

                        if model.state == .denied || isFailure {
                            weatherStatusCard
                        }

                        quickActions
                        localUpdatesCard
                        trustedSourceCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 30)
                }
                .refreshable {
                    model.refresh()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $isLocationPickerPresented) {
                LocationPickerSheet(model: model)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = model.state {
            return true
        }
        return false
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                isLocationPickerPresented = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.isUsingCurrentLocation ? "location.fill" : "mappin.and.ellipse")
                    Text(weather.location)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.bold())
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change weather location. Current selection: \(weather.location)")

            Spacer()

            Button {
                model.refresh()
            } label: {
                Group {
                    if model.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .font(.headline)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(model.isLoading)
            .accessibilityLabel("Refresh local weather")
        }
        .foregroundStyle(.white)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("TODAY’S HIGHLIGHT", systemImage: "sparkles")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(Color(red: 0.20, green: 0.16, blue: 0.42))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    LinearGradient(
                        colors: [.yellow.opacity(0.92), .orange.opacity(0.82)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(personalGreeting)
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.78))

                    Text("Your neighborhood")
                        .font(.system(size: 25, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .foregroundStyle(.white)

                    Text("right now")
                        .font(.system(size: 25, weight: .bold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                WeatherMascot(
                    condition: weather.condition,
                    size: 108,
                    usesIllustration: true
                )
            }

            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(weather.temperature)
                    .font(.system(size: 54, weight: .bold))

                VStack(alignment: .leading, spacing: 3) {
                    Text(weather.summary)
                        .font(.headline.weight(.semibold))
                    Text(weather.highLow)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .foregroundStyle(.white)

            Text(weather.condition.companionLine)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))

            HStack(spacing: 10) {
                WeatherMetric(
                    symbol: "drop.fill",
                    title: "Rain",
                    value: weather.precipitation
                )
                WeatherMetric(
                    symbol: "wind",
                    title: "Wind",
                    value: weather.wind
                )
            }

            HStack {
                Label(model.statusText, systemImage: weather.isLive ? "checkmark.seal.fill" : "location.circle")
                    .font(.caption.weight(.semibold))

                Spacer()
                Text(weather.updatedText)
                    .font(.caption)
            }
            .foregroundStyle(.white.opacity(0.74))
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.29, blue: 0.52).opacity(0.72),
                    Color(red: 0.29, green: 0.35, blue: 0.67).opacity(0.56)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 25, y: 14)
    }

    private var quickActions: some View {
        Button {
            selectedTab = .chat
        } label: {
            QuickActionLabel(
                title: "Ask your local companion",
                subtitle: "Get answers from trusted local sources",
                symbol: "bubble.left.fill",
                color: Color(red: 0.41, green: 0.28, blue: 0.94)
            )
        }
        .buttonStyle(.plain)
    }

    private var localUpdatesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("More local updates")
                        .font(.title3.bold())
                    Text("New trusted sources will appear here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Image(systemName: "wave.3.right")
                    .foregroundStyle(.purple)
            }
            .padding(.bottom, 8)

            LocalSignalRow(
                symbol: "tram.fill",
                color: .orange,
                title: "Transit",
                primary: "Live MBTA alerts connected",
                secondary: "Ask Chat about current service alerts",
                badge: "LIVE"
            )

            Divider().padding(.leading, 52)

            LocalSignalRow(
                symbol: "newspaper.fill",
                color: .green,
                title: "Local news",
                primary: "Trusted news feed coming soon",
                secondary: "Citations will appear with every answer",
                badge: nil
            )
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 9)
    }

    private var weatherStatusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.state == .denied ? "location.slash.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 5) {
                Text(model.state == .denied ? "Turn on your location" : "Weather needs another try")
                    .font(.subheadline.bold())
                Text(
                    model.state == .denied
                    ? "Allow location access so the companion can match the mascot and forecast to where you are."
                    : model.statusText
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(model.state == .denied ? "Settings" : "Retry") {
                if model.state == .denied,
                   let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    openURL(settingsURL)
                } else {
                    model.refresh()
                }
            }
            .font(.caption.bold())
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var trustedSourceCard: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.13))
                    .frame(width: 44, height: 44)
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Evidence, not guesses")
                    .font(.subheadline.bold())
                Text("Live weather links to its public source. Missing information is clearly labeled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let sourceURL = weather.sourceURL {
                Link(destination: sourceURL) {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.bold())
                        .padding(9)
                        .background(.purple.opacity(0.1), in: Circle())
                }
                .accessibilityLabel("Open Weather.gov source")
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return switch hour {
        case 5..<12: "GOOD MORNING"
        case 12..<17: "GOOD AFTERNOON"
        default: "GOOD EVENING"
        }
    }

    private var personalGreeting: String {
        guard let displayName, !displayName.isEmpty else {
            return greeting
        }
        return "\(greeting), \(displayName.uppercased())"
    }
}

private struct LocationPickerSheet: View {
    @ObservedObject var model: WeatherViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var isSearchFocused: Bool

    private let suggestedCities = ["Boston, MA", "New York, NY", "Washington, DC"]

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.91, green: 0.96, blue: 1.0),
                        Color(red: 0.95, green: 0.92, blue: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "location.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .blue)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.locationModeText)
                                    .font(.headline)
                                Text(model.locationHelpText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))

                        Button {
                            model.useCurrentLocation()
                            dismiss()
                        } label: {
                            Label("Use Current Location", systemImage: "location.fill")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(
                                    LinearGradient(
                                        colors: [.blue, Color(red: 0.38, green: 0.28, blue: 0.92)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 18)
                                )
                        }
                        .buttonStyle(.plain)

                        HStack {
                            Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
                            Text("OR SEARCH A CITY")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
                        }

                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)

                            TextField("City, state, or ZIP code", text: $searchText)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .focused($isSearchFocused)
                                .submitLabel(.search)
                                .onSubmit(search)

                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

                        Button(action: search) {
                            Group {
                                if isSearching {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text("Show This City")
                                        .font(.headline)
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                Color(red: 0.39, green: 0.25, blue: 0.90),
                                in: RoundedRectangle(cornerRadius: 18)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                        .opacity(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Quick choices")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(suggestedCities, id: \.self) { city in
                                        Button(city) {
                                            searchText = city
                                            search()
                                        }
                                        .font(.caption.weight(.semibold))
                                        .buttonStyle(.bordered)
                                        .tint(.purple)
                                    }
                                }
                            }
                        }

                        if case .failed(let message) = model.state {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Choose location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func search() {
        guard !isSearching else { return }
        isSearchFocused = false
        isSearching = true

        Task {
            let found = await model.searchCity(searchText)
            isSearching = false
            if found {
                dismiss()
            }
        }
    }
}

private struct WeatherMetric: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(.white.opacity(0.82))

            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                Text(value)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
    }
}

private struct QuickActionLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct LocalSignalRow: View {
    let symbol: String
    let color: Color
    let title: String
    let primary: String
    let secondary: String
    let badge: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.1), in: Capsule())
                    }
                }

                Text(primary)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
    }
}

private struct ChatView: View {
    @ObservedObject var model: WeatherViewModel

    @State private var question = ""
    @State private var isLoading = false
    @State private var isShowingTrustedSources = false
    @State private var isShowingHistory = false
    @State private var isShowingCommunityResponses = false
    @State private var isLoadingHistory = false
    @State private var isLoadingCommunityResponses = false
    @State private var historyError: String?
    @State private var communityResponseError: String?
    @State private var conversations: [ChatConversation] = []
    @State private var communityResponses: [CommunityJournalistResponse] = []
    @State private var activeConversationID: UUID?
    @State private var pendingConversationSave: Task<UUID, Error>?
    @State private var selectedCityWeather: WeatherSnapshot?
    @State private var messages = [
        ChatMessage(
            role: .assistant,
            text: "Hi! 👋 I’m your local companion. Ask me about the weather in your city or about something happening nearby. I’ll keep the answer simple, show my source, and be honest when I’m not sure.",
            state: nil,
            source: nil,
            sourceURL: nil
        )
    ]
    private let gapService = InformationGapService()
    private let chatService = ChatAPIService()
    private let historyService = ChatHistoryService()
    private let transitService = MBTAService()
    private let communityResponseService = CommunityResponseService()
    private let exampleQuestions = [
        "Will it rain?",
        "How windy is it?",
        "Why is the Green Line delayed?"
    ]

    private var weather: WeatherSnapshot {
        selectedCityWeather ?? model.weather
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WeatherBackdrop(
                    condition: weather.condition,
                    softened: true,
                    softeningOpacity: 0.38
                )

                VStack(spacing: 0) {
                    liveBanner
                    questionSuggestions
                    messagesList
                    inputBar
                }
            }
            .navigationTitle("Local Companion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingHistory = true
                        Task { await refreshConversations() }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Chat history")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            isShowingCommunityResponses = true
                            Task { await refreshCommunityResponses() }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "bell.fill")
                                if unreadCommunityResponseCount > 0 {
                                    Text("\(min(unreadCommunityResponseCount, 9))")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 15, height: 15)
                                        .background(.red, in: Circle())
                                        .offset(x: 7, y: -7)
                                }
                            }
                        }
                        .accessibilityLabel("Journalist responses")

                        Button(action: startNewChat) {
                            Image(systemName: "square.and.pencil")
                        }
                        .disabled(isLoading)
                        .accessibilityLabel("New chat")

                        WeatherMascot(condition: weather.condition, size: 38)
                    }
                }
            }
            .sheet(isPresented: $isShowingTrustedSources) {
                TrustedSourcesSheet()
            }
            .sheet(isPresented: $isShowingHistory) {
                ChatHistorySheet(
                    conversations: conversations,
                    activeConversationID: activeConversationID,
                    isLoading: isLoadingHistory,
                    errorMessage: historyError,
                    onSelect: { conversation in
                        Task { await loadConversation(conversation) }
                    },
                    onDelete: { conversation in
                        deleteConversation(conversation)
                    },
                    onNewChat: startNewChat
                )
            }
            .sheet(isPresented: $isShowingCommunityResponses) {
                CommunityResponsesSheet(
                    responses: communityResponses,
                    isLoading: isLoadingCommunityResponses,
                    errorMessage: communityResponseError,
                    onRefresh: {
                        Task { await refreshCommunityResponses() }
                    },
                    onMarkRead: { response in
                        Task { await markCommunityResponseRead(response) }
                    }
                )
            }
            .task {
                async let backendWarmup: Void = chatService.warmUp()
                async let historyRefresh: Void = refreshConversations()
                async let responseRefresh: Void = refreshCommunityResponses()
                await historyRefresh
                await responseRefresh
                await backendWarmup
            }
        }
    }

    private var liveBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: weather.isLive ? "checkmark.seal.fill" : "location.circle.fill")
            Text(
                weather.isLive
                    ? "\(weather.location) · \(weather.condition.title) · Weather.gov"
                    : model.statusText
            )
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(weather.isLive ? .indigo : .orange)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var questionSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(exampleQuestions, id: \.self) { example in
                    Button(example) {
                        question = example
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.purple)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.thinMaterial)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(messages) { message in
                        ChatBubble(
                            message: message,
                            condition: weather.condition,
                            onViewSources: {
                                isShowingTrustedSources = true
                            },
                            onRequestNotification: {
                                requestNotification(for: message.id)
                            }
                        )
                            .id(message.id)
                    }

                    if isLoading {
                        HStack(spacing: 10) {
                            WeatherMascot(condition: weather.condition, size: 36)
                            ProgressView("Checking trusted sources…")
                                .font(.caption)
                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) {
                guard let lastMessage = messages.last else { return }
                withAnimation {
                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about your area…", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .onChange(of: question) {
                    if question.count > 2_000 {
                        question = String(question.prefix(2_000))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

            Button(action: sendQuestion) {
                Image(systemName: "arrow.up")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.purple.gradient, in: Circle())
            }
            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            .opacity(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            .accessibilityLabel("Send question")
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func sendQuestion() {
        let submittedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedQuestion.isEmpty else { return }

        let conversationContext = messages
            .suffix(12)
            .map {
                ChatAPIHistoryMessage(
                    role: $0.role.storageValue,
                    content: $0.text
                )
            }
        let persistenceTask: Task<UUID, Error>
        if let conversationID = activeConversationID {
            persistenceTask = Task {
                try await historyService.saveUserMessage(
                    conversationID: conversationID,
                    question: submittedQuestion
                )
            }
        } else if let pendingConversationSave {
            // A quick follow-up can be sent after the answer appears but before
            // Supabase finishes creating the conversation. Chain that save to
            // the same conversation instead of creating a duplicate history row.
            persistenceTask = Task {
                let conversationID = try await pendingConversationSave.value
                return try await historyService.saveUserMessage(
                    conversationID: conversationID,
                    question: submittedQuestion
                )
            }
        } else {
            let firstSave = Task {
                try await historyService.saveUserMessage(
                    conversationID: nil,
                    question: submittedQuestion
                )
            }
            pendingConversationSave = firstSave
            persistenceTask = firstSave
        }

        messages.append(
            ChatMessage(
                role: .user,
                text: submittedQuestion,
                state: nil,
                source: nil,
                sourceURL: nil
            )
        )
        question = ""
        isLoading = true

        if needsTransitLocationClarification(submittedQuestion) {
            let clarification = ChatMessage(
                role: .assistant,
                text: "I can help with that. Which city, address, or landmark should I check? For Greater Boston, you can also open the Map tab, search an address, and tap a nearby MBTA stop for live arrivals.",
                state: nil,
                source: nil,
                sourceURL: nil
            )
            messages.append(clarification)
            persistAssistant(clarification, after: persistenceTask)
            isLoading = false
            return
        }

        Task { @MainActor in
            let weatherWords = [
                "weather", "forecast", "rain", "temperature", "temp", "sunny",
                "snow", "wind", "windy", "breeze", "umbrella", "precipitation",
                "outside", "tomorrow", "tonight", "cloud", "hot", "cold"
            ]
            let isWeatherQuestion = weatherWords.contains {
                submittedQuestion.localizedCaseInsensitiveContains($0)
            }
            let transitWords = [
                "mbta", "transit", "subway", "train", "bus", "commuter rail",
                "ferry", "green line", "red line", "orange line", "blue line",
                "silver line", "mattapan", "station", "service alert", "delayed",
                "delay"
            ]
            let isTransitQuestion = transitWords.contains {
                submittedQuestion.localizedCaseInsensitiveContains($0)
            }
            let arrivalWords = [
                "next", "arrive", "arrival", "departure", "depart", "leave",
                "schedule", "when is", "how long until"
            ]
            let isArrivalQuestion = isTransitQuestion && arrivalWords.contains {
                submittedQuestion.localizedCaseInsensitiveContains($0)
            }
            let normalizedQuestion = submittedQuestion.lowercased()
            let transitStatusWords = [
                "delay", "delayed", "service alert", "disruption",
                "problem", "not running", "closed", "closure"
            ]
            let asksAboutTransitStatus = transitStatusWords.contains {
                normalizedQuestion.contains($0)
            }
            var trustedWeather: WeatherSnapshot?
            var trustedTransit: MBTAAlertsSnapshot?
            var trustedArrivals: MBTAArrivalsSnapshot?

            if let routeRequest = requestedTransitRoute(in: submittedQuestion) {
                do {
                    async let origin = model.resolvePlace(routeRequest.origin)
                    async let destination = model.resolvePlace(routeRequest.destination)
                    let (resolvedOrigin, resolvedDestination) = try await (origin, destination)
                    let route = TransitRouteAction(
                        originName: resolvedOrigin.displayName,
                        originCoordinate: resolvedOrigin.coordinate,
                        destinationName: resolvedDestination.displayName,
                        destinationCoordinate: resolvedDestination.coordinate
                    )
                    var answer = "I found both places. Tap below and Apple Maps will compare the current public-transit options, travel times, transfers, and walking steps from \(resolvedOrigin.displayName) to \(resolvedDestination.displayName)."
                    var answerState: ChatMessage.AnswerState?
                    var source: String?
                    var sourceURL: URL?

                    // A directions request can also contain a civic question,
                    // such as “why is the Green Line delayed?”. Answer that
                    // question in the companion instead of replacing it with
                    // an Apple Maps button.
                    if asksAboutTransitStatus {
                        do {
                            let alerts = try await transitService.alerts(for: submittedQuestion)
                            let response = try await chatService.ask(
                                question: submittedQuestion,
                                weather: nil,
                                transit: alerts,
                                arrivals: nil,
                                history: conversationContext
                            )
                            let citation = response.citations.first
                            answer = response.answer + "\n\nFor the current fastest route, tap below to compare live public-transit options in Apple Maps."
                            answerState = response.status == .answered ? .cited : nil
                            source = citation?.title
                            sourceURL = citation?.url
                        } catch {
                            answer += "\n\nI found the route, but I couldn’t reach the live MBTA alert feed right now."
                        }
                    }

                    let routeMessage = ChatMessage(
                        role: .assistant,
                        text: answer,
                        state: answerState,
                        source: source,
                        sourceURL: sourceURL,
                        transitRoute: route
                    )
                    messages.append(routeMessage)
                    persistAssistant(routeMessage, after: persistenceTask)
                    isLoading = false
                    return
                } catch {
                    let routeError = ChatMessage(
                        role: .assistant,
                        text: "I couldn’t match one of those places. Try complete names such as “390 Riverway, Boston, MA” and “Northeastern University, Boston, MA.”",
                        state: .clarification,
                        source: nil,
                        sourceURL: nil
                    )
                    messages.append(routeError)
                    persistAssistant(routeError, after: persistenceTask)
                    isLoading = false
                    return
                }
            }

            if isWeatherQuestion {
                let requestedCity = requestedCity(in: submittedQuestion)

                if let requestedCity {
                    do {
                        let cityWeather = try await model.weather(forCity: requestedCity)
                        trustedWeather = cityWeather
                        withAnimation(.easeInOut(duration: 0.7)) {
                            selectedCityWeather = cityWeather
                        }
                    } catch {
                        let errorMessage = ChatMessage(
                            role: .assistant,
                            text: "Sorry, I couldn’t find \(requestedCity) in the National Weather Service coverage area. Could you try the city and state together—for example, “Boston, MA”?",
                            state: .clarification,
                            source: nil,
                            sourceURL: nil
                        )
                        messages.append(errorMessage)
                        persistAssistant(errorMessage, after: persistenceTask)
                        isLoading = false
                        return
                    }
                } else {
                    trustedWeather = weather
                }

                guard trustedWeather?.isLive == true else {
                    let errorMessage = ChatMessage(
                        role: .assistant,
                        text: "I’m missing your live location right now, so I don’t want to give you the wrong weather. Please refresh the Home screen, then ask me again.",
                        state: .setup,
                        source: nil,
                        sourceURL: nil
                    )
                    messages.append(errorMessage)
                    persistAssistant(errorMessage, after: persistenceTask)
                    isLoading = false
                    return
                }
            }

            if isTransitQuestion {
                do {
                    if isArrivalQuestion {
                        let arrivalLocation: ResolvedMapLocation
                        if let origin = requestedTransitOrigin(in: submittedQuestion) {
                            arrivalLocation = try await model.resolvePlace(origin)
                        } else if let coordinate = model.mapCoordinate {
                            arrivalLocation = ResolvedMapLocation(
                                coordinate: coordinate,
                                displayName: weather.location
                            )
                        } else {
                            let clarification = ChatMessage(
                                role: .assistant,
                                text: "Which Boston-area address or station should I check for the next arrival?",
                                state: nil,
                                source: nil,
                                sourceURL: nil
                            )
                            messages.append(clarification)
                            persistAssistant(clarification, after: persistenceTask)
                            isLoading = false
                            return
                        }

                        trustedArrivals = try await transitService.arrivals(
                            near: arrivalLocation.coordinate,
                            locationName: arrivalLocation.displayName,
                            question: submittedQuestion
                        )
                    } else {
                        trustedTransit = try await transitService.alerts(for: submittedQuestion)
                    }
                } catch {
                    let errorMessage = ChatMessage(
                        role: .assistant,
                        text: isArrivalQuestion
                            ? "I couldn’t find that starting location or load its live MBTA arrivals. Try a complete address such as “390 Riverway, Boston, MA.”"
                            : error.localizedDescription,
                        state: .setup,
                        source: nil,
                        sourceURL: nil
                    )
                    messages.append(errorMessage)
                    persistAssistant(errorMessage, after: persistenceTask)
                    isLoading = false
                    return
                }
            }

            do {
                let publishedJournalistAnswers = (
                    try? await communityResponseService.searchPublishedAnswers(
                        for: submittedQuestion
                    )
                ) ?? []
                let response: ChatAPIResponse
                response = try await chatService.ask(
                    question: submittedQuestion,
                    weather: trustedWeather,
                    transit: trustedTransit,
                    arrivals: trustedArrivals,
                    journalistAnswers: publishedJournalistAnswers,
                    history: conversationContext
                )
                let answerID = UUID()
                let citation = response.citations.first
                let answerState: ChatMessage.AnswerState?
                if response.status == .sourceUnavailable {
                    answerState = nil
                } else if response.outcome == "system_miss" {
                    answerState = .serviceUnavailable
                } else {
                    answerState = switch response.status {
                    case .answered: .cited
                    case .abstained: .abstained
                    case .outOfScope: .outOfScope
                    case .forecastUnavailable: .forecastUnavailable
                    case .conversational: nil
                    case .needsClarification: nil
                    case .sourceUnavailable: .setup
                    }
                }
                let shouldSaveGap = response.outcome == "true_gap"
                    || (response.outcome == nil && response.status == .abstained)

                let assistantMessage = ChatMessage(
                    id: answerID,
                    role: .assistant,
                    text: response.answer,
                    state: answerState,
                    source: citation?.title,
                    sourceURL: citation?.url,
                    gapSaveState: shouldSaveGap ? .saving : nil
                )
                messages.append(assistantMessage)
                persistAssistant(assistantMessage, after: persistenceTask)
                isLoading = false

                if shouldSaveGap {
                    do {
                        let savedID = try await gapService.logUnansweredQuestion(
                            question: submittedQuestion,
                            location: trustedWeather?.location ?? weather.location,
                            category: response.category,
                            confidence: response.confidence,
                            evidenceChecked: response.evidenceChecked,
                            assistantResponse: response.answer
                        )
                        updateMessage(answerID) { message in
                            message.remoteQuestionID = savedID
                            message.gapSaveState = .saved
                        }
                    } catch {
                        updateMessage(answerID) { message in
                            message.gapSaveState = .failed
                            message.actionError = informationGapSaveMessage(for: error)
                        }
                    }
                }
            } catch {
                let state: ChatMessage.AnswerState
                if let apiError = error as? ChatAPIError {
                    switch apiError {
                    case .server, .connectionFailed, .invalidResponse:
                        state = .serviceUnavailable
                    case .invalidConfiguration:
                        state = .setup
                    }
                } else {
                    state = .setup
                }
                let errorMessage = ChatMessage(
                    role: .assistant,
                    text: error.localizedDescription,
                    state: state,
                    source: nil,
                    sourceURL: nil
                )
                messages.append(errorMessage)
                persistAssistant(errorMessage, after: persistenceTask)
                isLoading = false
            }
        }
    }

    private func informationGapSaveMessage(for error: Error) -> String {
        let detail = error.localizedDescription
        let normalized = detail.lowercased()
        if normalized.contains("unanswered_questions")
            || normalized.contains("schema cache")
            || normalized.contains("pgrst205") {
            return "Journalist-review saving is not set up in Supabase yet. Run the unanswered-questions SQL migration once."
        }
        if normalized.contains("sign in again") || normalized.contains("jwt") {
            return "Sign in again, then resend the question so it can be saved for journalist review."
        }
        return "Couldn’t save this question for journalist review: \(detail)"
    }

    private var unreadCommunityResponseCount: Int {
        communityResponses.lazy.filter(\.isUnread).count
    }

    @MainActor
    private func refreshCommunityResponses() async {
        isLoadingCommunityResponses = true
        defer { isLoadingCommunityResponses = false }
        do {
            communityResponses = try await communityResponseService.notifications()
            communityResponseError = nil
        } catch {
            // Keep chat usable before the optional response-loop migration is
            // installed; the sheet explains the missing setup when opened.
            communityResponseError = error.localizedDescription
        }
    }

    @MainActor
    private func markCommunityResponseRead(_ response: CommunityJournalistResponse) async {
        do {
            try await communityResponseService.markRead(response.id)
            await refreshCommunityResponses()
        } catch {
            communityResponseError = error.localizedDescription
        }
    }

    private func needsTransitLocationClarification(_ submittedQuestion: String) -> Bool {
        let normalized = submittedQuestion.lowercased()
        let broadTransitPhrases = [
            "public transport", "public transportation", "transport available",
            "nearby transit", "nearest station", "closest station",
            "nearest bus", "closest bus"
        ]
        guard broadTransitPhrases.contains(where: normalized.contains) else {
            return false
        }

        let specificTransitTerms = [
            "mbta", "green line", "red line", "orange line", "blue line",
            "silver line", "mattapan", "commuter rail"
        ]
        if specificTransitTerms.contains(where: normalized.contains) {
            return false
        }

        // A street number usually means the user supplied a usable address.
        if normalized.range(of: #"\b\d{1,6}\b"#, options: .regularExpression) != nil {
            return false
        }

        let recognizedPlaces = [
            "boston", "brookline", "cambridge", "somerville", "newton",
            "quincy", "medford", "malden", "revere", "san francisco"
        ]
        return !recognizedPlaces.contains(where: normalized.contains)
    }

    private func requestedTransitOrigin(in submittedQuestion: String) -> String? {
        let patterns = [
            #"\bfrom\s+(.+?)(?:\s+to\s+|[?!.]*$)"#,
            #"\b(?:at|near)\s+(.+?)(?:\s+to\s+|[?!.]*$)"#
        ]

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(submittedQuestion.startIndex..., in: submittedQuestion)
            guard let match = expression.firstMatch(in: submittedQuestion, range: range),
                  match.numberOfRanges > 1,
                  let candidateRange = Range(match.range(at: 1), in: submittedQuestion) else {
                continue
            }

            let candidate = String(submittedQuestion[candidateRange])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !candidate.isEmpty {
                return candidate
            }
        }
        return nil
    }

    private func requestedTransitRoute(
        in submittedQuestion: String
    ) -> (origin: String, destination: String)? {
        let normalized = submittedQuestion.lowercased()
        let routeTerms = [
            "route", "transit", "transport", "travel", "directions",
            "fastest", "how do i get", "how can i get", "want to go"
        ]
        guard routeTerms.contains(where: normalized.contains) else { return nil }

        let pattern = #"\bfrom\s+(.+?)\s+to\s+(.+?)(?=\s+(?:i\s+want|what\s+is|which\s+is|how\s+can|please|and\s+tell)\b|[?!.]|$)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let fullRange = NSRange(submittedQuestion.startIndex..., in: submittedQuestion)
        guard let match = expression.firstMatch(in: submittedQuestion, range: fullRange),
              match.numberOfRanges > 2,
              let originRange = Range(match.range(at: 1), in: submittedQuestion),
              let destinationRange = Range(match.range(at: 2), in: submittedQuestion) else {
            return nil
        }

        let trimmingSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let origin = String(submittedQuestion[originRange])
            .trimmingCharacters(in: trimmingSet)
        let destination = String(submittedQuestion[destinationRange])
            .trimmingCharacters(in: trimmingSet)
        guard !origin.isEmpty, !destination.isEmpty else { return nil }
        return (origin, destination)
    }

    private func requestedCity(in submittedQuestion: String) -> String? {
        let lowercased = submittedQuestion.lowercased()
        let separators = [
            " weather of ", " weather for ", " weather in ",
            " forecast for ", " forecast in ", " in ", " near ", " is "
        ]
        let separatorRanges = separators.compactMap { separator in
            lowercased.range(of: separator, options: .backwards)
        }

        if let lastSeparator = separatorRanges.max(by: { $0.lowerBound < $1.lowerBound }),
           let city = cleanedCityCandidate(String(submittedQuestion[lastSeparator.upperBound...])) {
            return city
        }

        // Also understand natural phrases such as “Boston weather” or
        // “What is Boston weather?” where no preposition is present.
        if let weatherRange = lowercased.range(of: " weather", options: .backwards),
           let city = cleanedCityCandidate(String(submittedQuestion[..<weatherRange.lowerBound])) {
            return city
        }

        return nil
    }

    private func cleanedCityCandidate(_ rawCandidate: String) -> String? {
        let ignoredWords: Set<String> = [
            "hello", "hi", "hey", "please", "tell", "show", "me", "good",
            "morning", "afternoon", "evening", "what", "whats", "what’s",
            "will", "would", "can", "could", "is", "are", "be", "the", "a", "s",
            "an", "weather", "forecast", "today", "tonight", "right", "now",
            "tomorrow", "tomorrows", "tomorrow’s", "tommorrow", "tommorrows",
            "tommorrow’s", "tomorow", "tomoros", "like", "after", "before",
            "next", "this", "coming", "later", "on", "day", "days", "week",
            "weeks", "weekend", "month", "months", "monday", "tuesday",
            "wednesday", "thursday", "friday", "saturday", "sunday"
        ]
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let words = rawCandidate
            .components(separatedBy: separators)
            .filter { word in
                !word.isEmpty
                    && Int(word) == nil
                    && !ignoredWords.contains(word.lowercased())
            }

        guard !words.isEmpty, words.count <= 5 else { return nil }
        return words.joined(separator: " ")
    }

    private func startNewChat() {
        guard !isLoading else { return }
        activeConversationID = nil
        pendingConversationSave = nil
        selectedCityWeather = nil
        question = ""
        messages = [welcomeMessage]
        historyError = nil
        isShowingHistory = false
    }

    private var welcomeMessage: ChatMessage {
        ChatMessage(
            role: .assistant,
            text: "Hi! 👋 I’m your local companion. Ask me about the weather in your city or about something happening nearby. I’ll keep the answer simple, show my source, and be honest when I’m not sure.",
            state: nil,
            source: nil,
            sourceURL: nil
        )
    }

    @MainActor
    private func refreshConversations() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            conversations = try await historyService.conversations()
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    @MainActor
    private func loadConversation(_ conversation: ChatConversation) async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let storedMessages = try await historyService.messages(
                conversationID: conversation.id
            )
            activeConversationID = conversation.id
            pendingConversationSave = nil
            selectedCityWeather = nil
            messages = [welcomeMessage] + storedMessages.map(ChatMessage.init(stored:))
            historyError = nil
            isShowingHistory = false
        } catch {
            historyError = error.localizedDescription
        }
    }

    private func deleteConversation(_ conversation: ChatConversation) {
        Task { @MainActor in
            do {
                try await historyService.deleteConversation(conversation.id)
                conversations.removeAll { $0.id == conversation.id }
                if activeConversationID == conversation.id {
                    startNewChat()
                }
            } catch {
                historyError = error.localizedDescription
            }
        }
    }

    private func persistAssistant(
        _ message: ChatMessage,
        after userSaveTask: Task<UUID, Error>
    ) {
        Task { @MainActor in
            do {
                let conversationID = try await userSaveTask.value
                if messages.contains(where: { $0.id == message.id }) {
                    activeConversationID = conversationID
                }
                try await historyService.saveAssistantMessage(
                    conversationID: conversationID,
                    content: message.text,
                    answerState: message.state?.storageValue,
                    sourceTitle: message.source,
                    sourceURL: message.sourceURL
                )
                await refreshConversations()
            } catch {
                if activeConversationID == nil {
                    pendingConversationSave = nil
                }
                historyError = error.localizedDescription
            }
        }
    }

    private func updateMessage(_ id: UUID, update: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        update(&messages[index])
    }

    private func requestNotification(for messageID: UUID) {
        guard let message = messages.first(where: { $0.id == messageID }),
              let remoteQuestionID = message.remoteQuestionID,
              !message.notificationRequested,
              !message.isRequestingNotification else {
            return
        }

        updateMessage(messageID) { message in
            message.isRequestingNotification = true
            message.actionError = nil
        }

        Task { @MainActor in
            do {
                try await gapService.requestNotification(for: remoteQuestionID)
                updateMessage(messageID) { message in
                    message.isRequestingNotification = false
                    message.notificationRequested = true
                }
            } catch {
                updateMessage(messageID) { message in
                    message.isRequestingNotification = false
                    message.actionError = "The notification request could not be saved. Please try again."
                }
            }
        }
    }
}

private struct CommunityResponsesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let responses: [CommunityJournalistResponse]
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: () -> Void
    let onMarkRead: (CommunityJournalistResponse) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && responses.isEmpty {
                    ProgressView("Checking for journalist responses…")
                } else if let errorMessage, responses.isEmpty {
                    ContentUnavailableView(
                        "Responses are not ready",
                        systemImage: "exclamationmark.bubble",
                        description: Text(errorMessage)
                    )
                } else if responses.isEmpty {
                    ContentUnavailableView(
                        "No journalist responses yet",
                        systemImage: "newspaper",
                        description: Text("Verified answers to your saved community questions will appear here.")
                    )
                } else {
                    List {
                        if let errorMessage {
                            Section {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Section("Answers to your questions") {
                            ForEach(responses) { response in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(response.originalQuestion)
                                            .font(.headline)
                                        Spacer()
                                        if response.isUnread {
                                            Text("NEW")
                                                .font(.system(size: 9, weight: .black))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(.purple, in: Capsule())
                                        }
                                    }

                                    Text(response.answerText)
                                        .font(.body)

                                    Link(destination: response.sourceURL) {
                                        Label(response.sourceTitle, systemImage: "link")
                                            .font(.subheadline.weight(.semibold))
                                    }

                                    if response.isUnread {
                                        Button("Mark as read") {
                                            onMarkRead(response)
                                        }
                                        .font(.caption.weight(.semibold))
                                    }
                                }
                                .padding(.vertical, 7)
                            }
                        }

                        Section {
                            Text("Responses are delivered privately through the app. Journalists cannot see your email address, phone number, or account identity.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Journalist Responses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh journalist responses")
                }
            }
        }
    }
}

private struct ChatHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let conversations: [ChatConversation]
    let activeConversationID: UUID?
    let isLoading: Bool
    let errorMessage: String?
    let onSelect: (ChatConversation) -> Void
    let onDelete: (ChatConversation) -> Void
    let onNewChat: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && conversations.isEmpty {
                    ProgressView("Loading chats…")
                } else if let errorMessage, conversations.isEmpty {
                    ContentUnavailableView(
                        "Chat history is not ready",
                        systemImage: "exclamationmark.bubble",
                        description: Text(errorMessage)
                    )
                } else if conversations.isEmpty {
                    ContentUnavailableView(
                        "No saved chats",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Your first conversation will appear here after you send a message.")
                    )
                } else {
                    List {
                        if let errorMessage {
                            Section {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Section("Recent chats") {
                            ForEach(conversations) { conversation in
                                Button {
                                    onSelect(conversation)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "bubble.left.fill")
                                            .foregroundStyle(.purple)
                                            .frame(width: 34, height: 34)
                                            .background(.purple.opacity(0.1), in: Circle())

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(conversation.title)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(2)

                                            if let relativeUpdatedText = conversation.relativeUpdatedText {
                                                Text(relativeUpdatedText)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()

                                        if activeConversationID == conversation.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.purple)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        onDelete(conversation)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chat history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onNewChat()
                        dismiss()
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                }
            }
        }
    }
}

private struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant

        var storageValue: String {
            switch self {
            case .user: "user"
            case .assistant: "assistant"
            }
        }

        init(storageValue: String) {
            self = storageValue == "user" ? .user : .assistant
        }
    }

    enum AnswerState {
        case setup
        case clarification
        case cited
        case abstained
        case outOfScope
        case forecastUnavailable
        case serviceUnavailable

        var storageValue: String {
            switch self {
            case .setup: "setup"
            case .clarification: "clarification"
            case .cited: "cited"
            case .abstained: "abstained"
            case .outOfScope: "out_of_scope"
            case .forecastUnavailable: "forecast_unavailable"
            case .serviceUnavailable: "service_unavailable"
            }
        }

        init?(storageValue: String?) {
            switch storageValue {
            case "setup": self = .setup
            case "clarification": self = .clarification
            case "cited": self = .cited
            case "abstained": self = .abstained
            case "out_of_scope": self = .outOfScope
            case "forecast_unavailable": self = .forecastUnavailable
            case "service_unavailable": self = .serviceUnavailable
            default: return nil
            }
        }
    }

    enum GapSaveState {
        case saving
        case saved
        case failed
    }

    var id = UUID()
    let role: Role
    let text: String
    let state: AnswerState?
    let source: String?
    let sourceURL: URL?
    var transitRoute: TransitRouteAction? = nil
    var remoteQuestionID: UUID? = nil
    var gapSaveState: GapSaveState? = nil
    var isRequestingNotification = false
    var notificationRequested = false
    var actionError: String? = nil
}

private extension ChatMessage {
    init(stored: StoredChatMessage) {
        id = stored.id
        role = Role(storageValue: stored.role)
        text = stored.content
        state = AnswerState(storageValue: stored.answerState)
        source = stored.sourceTitle
        sourceURL = stored.sourceURL.flatMap(URL.init(string:))
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let condition: WeatherCondition
    let onViewSources: () -> Void
    let onRequestNotification: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if message.role == .assistant {
                WeatherMascot(condition: condition, size: 34)
            } else {
                Spacer(minLength: 52)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(message.text)
                    .font(.body)

                if let state = message.state {
                    answerStateLabel(state)
                }

                if let source = message.source {
                    Divider()

                    if let sourceURL = message.sourceURL {
                        Link(destination: sourceURL) {
                            Label(source, systemImage: "link")
                                .font(.caption)
                        }
                    } else {
                        Label(source, systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let route = message.transitRoute {
                    Button {
                        route.openInAppleMaps()
                    } label: {
                        Label("Open transit directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }

                if message.state == .abstained {
                    gapStatus
                    abstentionActions
                }

                if let actionError = message.actionError {
                    Text(actionError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(13)
            .background(message.role == .user ? Color.purple.opacity(0.9) : Color(.systemBackground))
            .foregroundStyle(message.role == .user ? .white : .primary)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 18,
                    bottomLeadingRadius: message.role == .assistant ? 5 : 18,
                    bottomTrailingRadius: message.role == .user ? 5 : 18,
                    topTrailingRadius: 18
                )
            )
            .shadow(color: .black.opacity(message.role == .assistant ? 0.06 : 0), radius: 8, y: 3)

            if message.role == .assistant {
                Spacer(minLength: 34)
            }
        }
    }

    @ViewBuilder
    private func answerStateLabel(_ state: ChatMessage.AnswerState) -> some View {
        switch state {
        case .setup:
            Label("Live connection required", systemImage: "location.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .clarification:
            Label("Location clarification needed", systemImage: "mappin.and.ellipse")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .cited:
            Label("Trusted evidence found", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .abstained:
            Label("No trusted answer", systemImage: "questionmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .outOfScope:
            Label("Out of scope · Not logged", systemImage: "nosign")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case .forecastUnavailable:
            Label("Outside the available forecast range", systemImage: "calendar.badge.exclamationmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .serviceUnavailable:
            Label("AI service temporarily unavailable", systemImage: "clock.badge.exclamationmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var gapStatus: some View {
        switch message.gapSaveState {
        case .saving:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving for information-gap review…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .saved:
            Label("Saved for journalist review", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .failed:
            Label("Not saved", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    private var abstentionActions: some View {
        VStack(spacing: 7) {
            Button(action: onViewSources) {
                Label("View trusted local sources", systemImage: "safari.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if message.gapSaveState == .saved {
                Button(action: onRequestNotification) {
                    if message.isRequestingNotification {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(
                            message.notificationRequested ? "Request saved" : "Notify me when available",
                            systemImage: message.notificationRequested ? "checkmark.circle.fill" : "bell.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(message.notificationRequested || message.isRequestingNotification)
            }
        }
    }
}

private struct TransitRouteAction {
    let originName: String
    let originCoordinate: CLLocationCoordinate2D
    let destinationName: String
    let destinationCoordinate: CLLocationCoordinate2D

    func openInAppleMaps() {
        let origin = MKMapItem(
            placemark: MKPlacemark(coordinate: originCoordinate)
        )
        origin.name = originName
        let destination = MKMapItem(
            placemark: MKPlacemark(coordinate: destinationCoordinate)
        )
        destination.name = destinationName

        MKMapItem.openMaps(
            with: [origin, destination],
            launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit
            ]
        )
    }
}

private struct TrustedSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SourceLinkRow(
                        title: "Weather.gov",
                        detail: "Connected for live forecasts",
                        symbol: "cloud.sun.fill",
                        color: .blue,
                        url: URL(string: "https://www.weather.gov")!
                    )
                    SourceLinkRow(
                        title: "MBTA",
                        detail: "Connected for live service alerts",
                        symbol: "tram.fill",
                        color: .orange,
                        url: URL(string: "https://www.mbta.com/alerts")!
                    )
                } header: {
                    Text("Connected sources")
                }

                Section {
                    SourceLinkRow(
                        title: "Boston 311",
                        detail: "Check city services directly",
                        symbol: "building.columns.fill",
                        color: .green,
                        url: URL(string: "https://www.boston.gov/departments/boston-311")!
                    )
                    SourceLinkRow(
                        title: "WCVB",
                        detail: "Check local reporting directly",
                        symbol: "newspaper.fill",
                        color: .red,
                        url: URL(string: "https://www.wcvb.com")!
                    )
                    SourceLinkRow(
                        title: "WBZ / CBS Boston",
                        detail: "Check local reporting directly",
                        symbol: "newspaper.fill",
                        color: .indigo,
                        url: URL(string: "https://www.cbsnews.com/boston/")!
                    )
                } header: {
                    Text("Helpful links · Not yet searched by the AI")
                } footer: {
                    Text("These links are offered as places to check. They are not citations unless the app used them to produce an answer.")
                }
            }
            .navigationTitle("Trusted local sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SourceLinkRow: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlannedFeatureView: View {
    let title: String
    let message: String
    let symbol: String
    let weather: WeatherSnapshot

    var body: some View {
        NavigationStack {
            ZStack {
                WeatherBackdrop(condition: weather.condition, softened: true)

                VStack(spacing: 18) {
                    WeatherMascot(condition: weather.condition, size: 96)

                    Image(systemName: symbol)
                        .font(.largeTitle)
                        .foregroundStyle(.purple)

                    Text(title)
                        .font(.title.bold())

                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Text("Planned milestone")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.purple.opacity(0.1), in: Capsule())
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct AccountProfileView: View {
    let email: String?
    let displayName: String?
    let weather: WeatherSnapshot
    let onSignOut: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var isShowingSignOutConfirmation = false
    @State private var hasJournalistAccess = false
    private let journalistService = JournalistGapService()

    var body: some View {
        NavigationStack {
            ZStack {
                WeatherBackdrop(condition: weather.condition, softened: true)

                List {
                    Section {
                        profileHeader
                            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 18, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    Section("Your area") {
                        ProfileSettingRow(
                            symbol: "location.fill",
                            color: .blue,
                            title: "Current location",
                            detail: weather.location
                        )

                        Button {
                            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                                openURL(settingsURL)
                            }
                        } label: {
                            ProfileSettingRow(
                                symbol: "location.circle.fill",
                                color: .indigo,
                                title: "Location access",
                                detail: "Manage in Settings",
                                showsChevron: true
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Section("Trusted connections") {
                        ProfileSettingRow(
                            symbol: weather.isLive ? "checkmark.shield.fill" : "clock.fill",
                            color: weather.isLive ? .green : .orange,
                            title: "Weather.gov",
                            detail: weather.isLive ? "Connected · Live" : "Connecting"
                        )

                        if let sourceURL = weather.sourceURL {
                            Link(destination: sourceURL) {
                                ProfileSettingRow(
                                    symbol: "safari.fill",
                                    color: .cyan,
                                    title: "View weather source",
                                    detail: "Opens Weather.gov",
                                    showsChevron: true
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if hasJournalistAccess {
                        Section("Editorial tools") {
                            NavigationLink {
                                JournalistDashboardView()
                            } label: {
                                ProfileSettingRow(
                                    symbol: "newspaper.fill",
                                    color: .purple,
                                    title: "Journalist Inbox",
                                    detail: "Review clustered information gaps",
                                    showsChevron: true
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            isShowingSignOutConfirmation = true
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } header: {
                        Text("Account")
                    } footer: {
                        Text("Local Companion · Version 1.0")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .task {
                hasJournalistAccess = await journalistService.hasJournalistAccess()
            }
            .confirmationDialog(
                "Sign out of Local Companion?",
                isPresented: $isShowingSignOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive, action: onSignOut)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will need your email and password to sign in again.")
            }
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.indigo, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 82, height: 82)

                Text(accountInitials)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)

                Image(systemName: "checkmark.seal.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.title3)
                    .background(.white, in: Circle())
            }

            VStack(spacing: 4) {
                Text(displayName ?? "Local Companion member")
                    .font(.title3.weight(.semibold))

                Text(email ?? "Signed-in account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("Verified account")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var accountInitials: String {
        if let displayName {
            let words = displayName.split(separator: " ")
            let initials = words.prefix(2).compactMap(\.first).map(String.init).joined()
            if !initials.isEmpty {
                return initials.uppercased()
            }
        }
        return email?.first.map { String($0).uppercased() } ?? "LC"
    }
}

private struct ProfileSettingRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    var showsChevron = false

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
