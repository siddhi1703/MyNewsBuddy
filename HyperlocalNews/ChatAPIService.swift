import Foundation

struct ChatAPIResponse: Decodable {
    enum Status: String, Decodable {
        case answered
        case abstained
        case outOfScope = "out_of_scope"
        case forecastUnavailable = "forecast_unavailable"
    }

    struct Citation: Decodable {
        let title: String
        let url: URL
    }

    let answer: String
    let status: Status
    var outcome: String? = nil
    let category: String
    let confidence: Double
    let citations: [Citation]
}

struct ChatAPIHistoryMessage: Encodable {
    let role: String
    let content: String
}

/// Builds fast, fully grounded answers for simple questions whose facts are
/// already present in the official NWS or MBTA response. This avoids spending
/// an LLM request merely to reformat structured live data.
struct FastTrustedAnswerService {
    func answer(
        question: String,
        weather: WeatherSnapshot?,
        transit: MBTAAlertsSnapshot?,
        arrivals: MBTAArrivalsSnapshot?
    ) -> ChatAPIResponse? {
        let evidenceCount = [weather != nil, transit != nil, arrivals != nil]
            .filter { $0 }
            .count
        guard evidenceCount == 1 else { return nil }

        if let arrivals {
            return arrivalAnswer(from: arrivals)
        }
        if let transit {
            return alertAnswer(from: transit)
        }
        if let weather {
            return weatherAnswer(question: question, weather: weather)
        }
        return nil
    }

    private func weatherAnswer(
        question: String,
        weather: WeatherSnapshot
    ) -> ChatAPIResponse {
        let normalized = question.lowercased()
        let citation = ChatAPIResponse.Citation(
            title: "National Weather Service forecast for \(weather.location)",
            url: weather.sourceURL ?? URL(string: "https://www.weather.gov")!
        )

        if asksBeyondForecastRange(normalized) {
            let lastDate = weather.forecastPeriods
                .map(\.startTime)
                .max()?
                .formatted(date: .abbreviated, time: .omitted)
            let availableThrough = lastDate.map { " through \($0)" } ?? ""
            return ChatAPIResponse(
                answer: "I can’t give you a trustworthy forecast that far ahead. The Weather.gov forecast currently available in the app only extends\(availableThrough). Ask me again when the date is closer.",
                status: .forecastUnavailable,
                category: "weather",
                confidence: 1,
                citations: [citation]
            )
        }

        if normalized.contains("tomorrow"),
           let period = tomorrowPeriod(in: weather) {
            return ChatAPIResponse(
                answer: "Tomorrow in \(weather.location), Weather.gov forecasts \(period.summary.lowercased()), around \(period.formattedTemperature). The rain chance is \(period.precipitationChance)%, with winds \(period.wind).",
                status: .answered,
                category: "weather",
                confidence: 1,
                citations: [citation]
            )
        }

        if normalized.contains("tonight"),
           let period = weather.forecastPeriods.first(where: {
               $0.name.localizedCaseInsensitiveContains("tonight")
           }) {
            return ChatAPIResponse(
                answer: "Tonight in \(weather.location), expect \(period.summary.lowercased()) near \(period.formattedTemperature). The rain chance is \(period.precipitationChance)%, with winds \(period.wind).",
                status: .answered,
                category: "weather",
                confidence: 1,
                citations: [citation]
            )
        }

        let answer: String
        if normalized.contains("wind") || normalized.contains("breeze") {
            answer = "Winds near \(weather.location) are \(weather.wind) right now. The current Weather.gov forecast is \(weather.summary.lowercased()) at \(weather.temperature)."
        } else if normalized.contains("rain")
                    || normalized.contains("umbrella")
                    || normalized.contains("precipitation") {
            answer = "The current rain chance near \(weather.location) is \(weather.precipitation). The forecast is \(weather.summary.lowercased()) at \(weather.temperature), so keep that in mind before heading out."
        } else {
            answer = "Right now near \(weather.location), it’s \(weather.temperature) with \(weather.summary.lowercased()). The rain chance is \(weather.precipitation), and winds are \(weather.wind)."
        }

        return ChatAPIResponse(
            answer: answer,
            status: .answered,
            category: "weather",
            confidence: 1,
            citations: [citation]
        )
    }

    private func arrivalAnswer(from snapshot: MBTAArrivalsSnapshot) -> ChatAPIResponse {
        let citation = ChatAPIResponse.Citation(
            title: snapshot.title,
            url: snapshot.sourceURL
        )
        let rows = snapshot.stops.flatMap { item in
            item.predictions.prefix(2).map { prediction in
                let platform = item.stop.platformName.map { " — \($0) platform" } ?? ""
                let destination = prediction.destination.map { " toward \($0)" } ?? ""
                return "• \(item.stop.name)\(platform): \(prediction.routeName)\(destination) — \(prediction.arrivalText) (\(prediction.clockText))"
            }
        }

        let answer: String
        if rows.isEmpty {
            answer = "I checked the official MBTA feed near \(snapshot.queryLocation), but it isn’t publishing an upcoming arrival right now. Try refreshing in a minute or choose a nearby stop in the Map tab."
        } else {
            answer = "Here are the next official MBTA predictions near \(snapshot.queryLocation):\n" + rows.prefix(6).joined(separator: "\n") + "\nTimes are live predictions and can change."
        }

        return ChatAPIResponse(
            answer: answer,
            status: .answered,
            category: "transit",
            confidence: 1,
            citations: [citation]
        )
    }

    private func alertAnswer(from snapshot: MBTAAlertsSnapshot) -> ChatAPIResponse {
        let citation = ChatAPIResponse.Citation(
            title: snapshot.title,
            url: snapshot.sourceURL
        )
        let answer: String
        if snapshot.alerts.isEmpty {
            answer = "I checked the official MBTA feed and found no active alert matching \(snapshot.scope) right now. That means no matching alert is published—it doesn’t guarantee there are no minor delays."
        } else {
            let alerts = snapshot.alerts.prefix(3).map { "• \($0.headline)" }
            answer = "The MBTA currently has \(snapshot.alerts.count) matching alert\(snapshot.alerts.count == 1 ? "" : "s") for \(snapshot.scope):\n" + alerts.joined(separator: "\n")
        }
        return ChatAPIResponse(
            answer: answer,
            status: .answered,
            category: "transit",
            confidence: 1,
            citations: [citation]
        )
    }

    private func asksBeyondForecastRange(_ question: String) -> Bool {
        if question.contains("two weeks")
            || question.contains("three weeks")
            || question.contains("next month") {
            return true
        }
        guard let expression = try? NSRegularExpression(
            pattern: #"\b(?:after|in)\s+(\d+)\s+days?\b"#
        ),
        let match = expression.firstMatch(
            in: question,
            range: NSRange(question.startIndex..., in: question)
        ),
        match.numberOfRanges > 1,
        let range = Range(match.range(at: 1), in: question),
        let days = Int(question[range]) else {
            return false
        }
        return days > 7
    }

    private func tomorrowPeriod(in weather: WeatherSnapshot) -> ForecastPeriodSnapshot? {
        if let named = weather.forecastPeriods.first(where: {
            $0.name.localizedCaseInsensitiveContains("tomorrow")
        }) {
            return named
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: weather.timeZoneIdentifier) ?? .autoupdatingCurrent
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) else {
            return nil
        }
        return weather.forecastPeriods.first {
            calendar.isDate($0.startTime, inSameDayAs: tomorrow) && $0.isDaytime
        } ?? weather.forecastPeriods.first {
            calendar.isDate($0.startTime, inSameDayAs: tomorrow)
        }
    }
}

enum ChatAPIError: LocalizedError {
    case invalidConfiguration
    case invalidResponse
    case server(statusCode: Int, detail: String)
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The AI service URL is not configured."
        case .invalidResponse:
            "The AI service returned an unexpected response."
        case .server(_, let detail):
            detail
        case .connectionFailed:
            "The AI service is not reachable. Start the FastAPI backend, then try again."
        }
    }
}

struct ChatAPIService {
    private struct AskRequest: Encodable {
        let question: String
        let location: String?
        let evidence: [Evidence]
        let history: [ChatAPIHistoryMessage]
    }

    private struct Evidence: Encodable {
        let sourceID: String
        let title: String
        let url: URL
        let text: String
        let retrievedAt: String
    }

    private struct ErrorResponse: Decodable {
        let detail: String?
    }

    func ask(
        question: String,
        weather: WeatherSnapshot?,
        transit: MBTAAlertsSnapshot? = nil,
        arrivals: MBTAArrivalsSnapshot? = nil,
        history: [ChatAPIHistoryMessage] = []
    ) async throws -> ChatAPIResponse {
        guard let baseURL = AppConfiguration.chatAPIBaseURL else {
            throw ChatAPIError.invalidConfiguration
        }

        var evidence: [Evidence] = []
        if let weather {
            evidence.append(weatherEvidence(from: weather))
        }
        if let transit {
            evidence.append(transitEvidence(from: transit))
        }
        if let arrivals {
            evidence.append(arrivalEvidence(from: arrivals))
        }
        let body = AskRequest(
            question: question,
            location: weather?.location ?? arrivals?.queryLocation ?? transit?.scope,
            evidence: evidence,
            history: Array(history.suffix(20))
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("ask"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ChatAPIError.connectionFailed
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrorResponse.self, from: data).detail)
                ?? "The AI service could not answer right now."
            throw ChatAPIError.server(statusCode: httpResponse.statusCode, detail: detail)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ChatAPIResponse.self, from: data)
        } catch {
            throw ChatAPIError.invalidResponse
        }
    }

    private func weatherEvidence(from weather: WeatherSnapshot) -> Evidence {
        let formatter = ISO8601DateFormatter()
        let periodLines = weather.forecastPeriods.map { period in
            [
                "name=\(period.name)",
                "start_time=\(formatter.string(from: period.startTime))",
                "daytime=\(period.isDaytime)",
                "temperature=\(period.formattedTemperature)",
                "precipitation_chance=\(period.precipitationChance)%",
                "wind=\(period.wind)",
                "forecast=\(period.summary)"
            ].joined(separator: "; ")
        }

        let evidenceText = ([
            "Location: \(weather.location)",
            "Time zone: \(weather.timeZoneIdentifier)",
            "Current hourly forecast: temperature=\(weather.temperature); forecast=\(weather.summary); precipitation_chance=\(weather.precipitation); wind=\(weather.wind)",
            "Next 12 hours: \(weather.highLow)",
            "Forecast periods:"
        ] + periodLines).joined(separator: "\n")

        return Evidence(
            sourceID: "nws-forecast",
            title: "National Weather Service forecast for \(weather.location)",
            url: weather.sourceURL ?? URL(string: "https://www.weather.gov")!,
            text: evidenceText,
            retrievedAt: formatter.string(from: .now)
        )
    }

    private func transitEvidence(from transit: MBTAAlertsSnapshot) -> Evidence {
        let formatter = ISO8601DateFormatter()
        return Evidence(
            sourceID: "mbta-alerts",
            title: transit.title,
            url: transit.sourceURL,
            text: transit.evidenceText,
            retrievedAt: formatter.string(from: transit.retrievedAt)
        )
    }

    private func arrivalEvidence(from arrivals: MBTAArrivalsSnapshot) -> Evidence {
        let formatter = ISO8601DateFormatter()
        return Evidence(
            sourceID: "mbta-predictions",
            title: arrivals.title,
            url: arrivals.sourceURL,
            text: arrivals.evidenceText,
            retrievedAt: formatter.string(from: arrivals.retrievedAt)
        )
    }
}
