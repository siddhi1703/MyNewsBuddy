import CoreLocation
import Foundation
import MapKit
import SwiftUI

enum WeatherCondition: String {
    case sunny
    case cloudy
    case rainy
    case snowy
    case stormy
    case foggy
    case night

    var title: String {
        switch self {
        case .sunny: "Sunny"
        case .cloudy: "Cloudy"
        case .rainy: "Rainy"
        case .snowy: "Snowy"
        case .stormy: "Stormy"
        case .foggy: "Foggy"
        case .night: "Clear night"
        }
    }

    var symbol: String {
        switch self {
        case .sunny: "sun.max.fill"
        case .cloudy: "cloud.sun.fill"
        case .rainy: "cloud.rain.fill"
        case .snowy: "cloud.snow.fill"
        case .stormy: "cloud.bolt.rain.fill"
        case .foggy: "cloud.fog.fill"
        case .night: "moon.stars.fill"
        }
    }

    var mascotAssetName: String {
        switch self {
        case .sunny: "WeatherMascotSunny"
        case .cloudy, .foggy: "WeatherMascotCloudy"
        case .rainy: "WeatherMascotRainy"
        case .snowy: "WeatherMascotSnowy"
        case .stormy: "WeatherMascotStormy"
        case .night: "WeatherMascotNight"
        }
    }

    var companionLine: String {
        switch self {
        case .sunny: "Sunshine is leading today."
        case .cloudy: "Clouds are keeping things calm."
        case .rainy: "I brought the rain—take an umbrella."
        case .snowy: "Snow mode is on. Travel carefully."
        case .stormy: "Storm watch mode is active."
        case .foggy: "Visibility may be lower nearby."
        case .night: "Your night-sky companion is here."
        }
    }

    var colors: [Color] {
        switch self {
        case .sunny:
            [
                Color(red: 0.24, green: 0.64, blue: 1.0),
                Color(red: 0.64, green: 0.74, blue: 1.0),
                Color(red: 1.0, green: 0.72, blue: 0.68)
            ]
        case .cloudy:
            [
                Color(red: 0.39, green: 0.68, blue: 0.91),
                Color(red: 0.62, green: 0.80, blue: 0.94),
                Color(red: 0.86, green: 0.91, blue: 0.91)
            ]
        case .rainy:
            [
                Color(red: 0.08, green: 0.20, blue: 0.38),
                Color(red: 0.20, green: 0.43, blue: 0.64),
                Color(red: 0.41, green: 0.65, blue: 0.78)
            ]
        case .snowy:
            [
                Color(red: 0.36, green: 0.58, blue: 0.75),
                Color(red: 0.70, green: 0.84, blue: 0.92),
                Color(red: 0.91, green: 0.96, blue: 1.0)
            ]
        case .stormy:
            [
                Color(red: 0.08, green: 0.10, blue: 0.22),
                Color(red: 0.24, green: 0.25, blue: 0.46),
                Color(red: 0.48, green: 0.39, blue: 0.67)
            ]
        case .foggy:
            [
                Color(red: 0.35, green: 0.46, blue: 0.54),
                Color(red: 0.64, green: 0.72, blue: 0.75),
                Color(red: 0.86, green: 0.88, blue: 0.86)
            ]
        case .night:
            [
                Color(red: 0.03, green: 0.07, blue: 0.18),
                Color(red: 0.10, green: 0.17, blue: 0.38),
                Color(red: 0.27, green: 0.22, blue: 0.52)
            ]
        }
    }

    var accent: Color {
        switch self {
        case .sunny: .yellow
        case .cloudy: Color(red: 0.78, green: 0.88, blue: 0.96)
        case .rainy: .cyan
        case .snowy: .white
        case .stormy: .yellow
        case .foggy: Color(red: 0.88, green: 0.93, blue: 0.94)
        case .night: Color(red: 0.73, green: 0.69, blue: 1.0)
        }
    }

    static func from(summary: String, isDaytime: Bool) -> WeatherCondition {
        let value = summary.lowercased()

        if value.contains("thunder") || value.contains("storm") {
            return .stormy
        }
        if value.contains("snow") || value.contains("sleet") || value.contains("ice") || value.contains("flurr") {
            return .snowy
        }
        if value.contains("rain") || value.contains("shower") || value.contains("drizzle") {
            return .rainy
        }
        if value.contains("fog") || value.contains("mist") || value.contains("haze") {
            return .foggy
        }

        // NWS marks each forecast period as daytime or nighttime. For dry
        // nighttime conditions, show the moon companion even when clouds are
        // mentioned in the summary.
        if !isDaytime {
            return .night
        }

        if value.contains("cloud") || value.contains("overcast") {
            return .cloudy
        }
        return .sunny
    }
}

struct WeatherSnapshot {
    let condition: WeatherCondition
    let temperature: String
    let summary: String
    let highLow: String
    let location: String
    let updatedText: String
    let precipitation: String
    let wind: String
    let sourceURL: URL?
    let isLive: Bool
    let timeZoneIdentifier: String
    let forecastPeriods: [ForecastPeriodSnapshot]

    static let waiting = WeatherSnapshot(
        condition: .sunny,
        temperature: "—",
        summary: "Waiting for your location",
        highLow: "Live local forecast",
        location: "Your location",
        updatedText: "Not updated yet",
        precipitation: "—",
        wind: "—",
        sourceURL: URL(string: "https://www.weather.gov"),
        isLive: false,
        timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
        forecastPeriods: []
    )
}

struct ForecastPeriodSnapshot {
    let name: String
    let startTime: Date
    let isDaytime: Bool
    let temperature: Int
    let temperatureUnit: String
    let precipitationChance: Int
    let wind: String
    let summary: String

    var formattedTemperature: String {
        "\(temperature)°\(temperatureUnit)"
    }
}

struct ResolvedMapLocation {
    let coordinate: CLLocationCoordinate2D
    let displayName: String
}

enum WeatherLoadingState: Equatable {
    case waiting
    case requestingLocation
    case loadingWeather
    case ready
    case denied
    case failed(String)
}

@MainActor
final class WeatherViewModel: NSObject, ObservableObject {
    @Published private(set) var weather = WeatherSnapshot.waiting
    @Published private(set) var state = WeatherLoadingState.waiting
    @Published private(set) var isUsingCurrentLocation = true
    @Published private(set) var mapCoordinate: CLLocationCoordinate2D?

    private let locationManager = CLLocationManager()
    private var started = false
    private var selectedCityLocation: CLLocation?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isLoading: Bool {
        state == .requestingLocation || state == .loadingWeather
    }

    var statusText: String {
        switch state {
        case .waiting: "Ready for live weather"
        case .requestingLocation: "Finding your location…"
        case .loadingWeather: "Loading Weather.gov…"
        case .ready: "Live · Weather.gov"
        case .denied: "Location access is off"
        case .failed(let message): message
        }
    }

    var locationModeText: String {
        isUsingCurrentLocation ? "Current location" : "Selected city"
    }

    var locationHelpText: String {
#if targetEnvironment(simulator)
        "The iPhone Simulator uses the location selected in Xcode. Choose a city here, or run the app on a real iPhone for live GPS."
#else
        "Current Location uses this iPhone’s GPS. You can also search for another U.S. city."
#endif
    }

    func start() {
        guard !started else { return }
        started = true
        requestWeather()
    }

    func refresh() {
        if let selectedCityLocation {
            loadWeather(for: selectedCityLocation)
        } else {
            requestWeather()
        }
    }

    func useCurrentLocation() {
        selectedCityLocation = nil
        isUsingCurrentLocation = true
        mapCoordinate = nil
        requestWeather()
    }

    func searchCity(_ query: String) async -> Bool {
        let city = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else {
            state = .failed("Enter a U.S. city or ZIP code.")
            return false
        }

        state = .requestingLocation
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = city
        request.resultTypes = .address

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let coordinate = response.mapItems.first?.placemark.location else {
                state = .failed("We couldn’t find that city. Try a city and state, such as Boston, MA.")
                return false
            }

            selectedCityLocation = coordinate
            isUsingCurrentLocation = false
            mapCoordinate = coordinate.coordinate
            loadWeather(for: coordinate)
            return true
        } catch {
            state = .failed("We couldn’t find that city. Try again.")
            return false
        }
    }

    func weather(forCity query: String) async throws -> WeatherSnapshot {
        let city = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else {
            throw WeatherServiceError.cityNotFound
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = city
        request.resultTypes = .address

        let response = try await MKLocalSearch(request: request).start()
        guard let location = response.mapItems.first?.placemark.location else {
            throw WeatherServiceError.cityNotFound
        }
        return try await WeatherService.fetchWeather(at: location.coordinate)
    }

    func resolvePlace(_ query: String) async throws -> ResolvedMapLocation {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw WeatherServiceError.cityNotFound
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = value
        request.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw WeatherServiceError.cityNotFound
        }

        let placemark = item.placemark
        let place = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cityState = [placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let displayName: String
        if let place, !place.isEmpty, place != placemark.locality {
            displayName = cityState.isEmpty ? place : "\(place) · \(cityState)"
        } else {
            displayName = cityState.isEmpty ? value : cityState
        }

        return ResolvedMapLocation(
            coordinate: placemark.coordinate,
            displayName: displayName
        )
    }

    private func requestWeather() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            state = .requestingLocation
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            state = .requestingLocation
            locationManager.requestLocation()
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .failed("Location is temporarily unavailable")
        }
    }

    private func loadWeather(for location: CLLocation) {
        state = .loadingWeather

        Task {
            do {
                weather = try await WeatherService.fetchWeather(at: location.coordinate)
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

extension WeatherViewModel: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            state = .requestingLocation
            manager.requestLocation()
        case .denied, .restricted:
            state = .denied
        case .notDetermined:
            break
        @unknown default:
            state = .failed("Location is temporarily unavailable")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard selectedCityLocation == nil else { return }
        guard let location = locations
            .filter({ $0.horizontalAccuracy >= 0 })
            .max(by: { $0.timestamp < $1.timestamp }) else {
            state = .failed("No current location was returned")
            return
        }
        mapCoordinate = location.coordinate
        loadWeather(for: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        state = .failed("Couldn’t find your location. Try again.")
    }
}

private enum WeatherService {
    static func fetchWeather(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        let latitude = String(format: "%.4f", coordinate.latitude)
        let longitude = String(format: "%.4f", coordinate.longitude)
        guard let pointURL = URL(string: "https://api.weather.gov/points/\(latitude),\(longitude)") else {
            throw WeatherServiceError.invalidURL
        }

        let point: WeatherPointResponse = try await request(pointURL)
        async let hourlyRequest: HourlyForecastResponse = request(point.properties.forecastHourly)
        async let dailyRequest: DailyForecastResponse = request(point.properties.forecast)
        let (hourly, daily) = try await (hourlyRequest, dailyRequest)

        guard let current = hourly.properties.periods.first else {
            throw WeatherServiceError.noForecast
        }

        let nextTemperatures = hourly.properties.periods.prefix(12).map(\.temperature)
        let high = nextTemperatures.max() ?? current.temperature
        let low = nextTemperatures.min() ?? current.temperature
        let location = [
            point.properties.relativeLocation?.properties.city,
            point.properties.relativeLocation?.properties.state
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")

        // Show when this device actually received the forecast. The NWS `updateTime`
        // is the forecast issue time and may legitimately be several hours earlier.
        let updatedText = "Updated \(Date.now.formatted(date: .omitted, time: .shortened))"

        let temperatureUnit = current.temperatureUnit == "C" ? "°C" : "°F"
        let chance = Int(current.probabilityOfPrecipitation?.value ?? 0)
        let dateFormatter = ISO8601DateFormatter()
        let forecastPeriods = daily.properties.periods.compactMap { period -> ForecastPeriodSnapshot? in
            guard let startTime = dateFormatter.date(from: period.startTime) else {
                return nil
            }
            return ForecastPeriodSnapshot(
                name: period.name,
                startTime: startTime,
                isDaytime: period.isDaytime,
                temperature: period.temperature,
                temperatureUnit: period.temperatureUnit,
                precipitationChance: Int(period.probabilityOfPrecipitation?.value ?? 0),
                wind: period.windSpeed,
                summary: period.shortForecast
            )
        }
        var readableSource = URLComponents(string: "https://forecast.weather.gov/MapClick.php")
        readableSource?.queryItems = [
            URLQueryItem(name: "lat", value: latitude),
            URLQueryItem(name: "lon", value: longitude)
        ]

        return WeatherSnapshot(
            condition: WeatherCondition.from(
                summary: current.shortForecast,
                isDaytime: current.isDaytime
            ),
            temperature: "\(current.temperature)\(temperatureUnit)",
            summary: current.shortForecast,
            highLow: "Next 12h · H \(high)°  L \(low)°",
            location: location.isEmpty ? "Current location" : location,
            updatedText: updatedText,
            precipitation: "\(chance)%",
            wind: current.windSpeed,
            sourceURL: readableSource?.url,
            isLive: true,
            timeZoneIdentifier: point.properties.timeZone,
            forecastPeriods: forecastPeriods
        )
    }

    private static func request<Response: Decodable>(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.setValue(
            "LocalCompanion/1.0 (student hyperlocal news research app)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw WeatherServiceError.serverUnavailable
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WeatherServiceError.invalidResponse
        }
    }
}

private enum WeatherServiceError: LocalizedError {
    case invalidURL
    case serverUnavailable
    case invalidResponse
    case noForecast
    case cityNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The weather location could not be prepared."
        case .serverUnavailable:
            "Weather.gov is temporarily unavailable."
        case .invalidResponse:
            "Weather.gov returned an unexpected response."
        case .noForecast:
            "No forecast is available for this location."
        case .cityNotFound:
            "That city could not be found. Try a U.S. city and state, such as Boston, MA."
        }
    }
}

private struct WeatherPointResponse: Decodable {
    let properties: Properties

    struct Properties: Decodable {
        let forecast: URL
        let forecastHourly: URL
        let timeZone: String
        let relativeLocation: RelativeLocation?
    }
}

private struct RelativeLocation: Decodable {
    let properties: Properties

    struct Properties: Decodable {
        let city: String?
        let state: String?
    }
}

private struct HourlyForecastResponse: Decodable {
    let properties: Properties

    struct Properties: Decodable {
        let periods: [Period]
    }
}

private struct DailyForecastResponse: Decodable {
    let properties: Properties

    struct Properties: Decodable {
        let periods: [DailyPeriod]
    }
}

private struct DailyPeriod: Decodable {
    let name: String
    let startTime: String
    let isDaytime: Bool
    let temperature: Int
    let temperatureUnit: String
    let probabilityOfPrecipitation: QuantitativeValue?
    let windSpeed: String
    let shortForecast: String
}

private struct Period: Decodable {
    let isDaytime: Bool
    let temperature: Int
    let temperatureUnit: String
    let probabilityOfPrecipitation: QuantitativeValue?
    let windSpeed: String
    let shortForecast: String
}

private struct QuantitativeValue: Decodable {
    let value: Double?
}
