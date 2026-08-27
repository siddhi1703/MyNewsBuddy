import Foundation

struct ChatAPIResponse: Decodable {
    enum Status: String, Decodable {
        case answered
        case abstained
        case outOfScope = "out_of_scope"
        case forecastUnavailable = "forecast_unavailable"
        case conversational
        case needsClarification = "needs_clarification"
        case sourceUnavailable = "source_unavailable"
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
    let evidenceChecked: [String]
}

struct ChatAPIHistoryMessage: Encodable {
    let role: String
    let content: String
}

enum ChatAPIError: LocalizedError {
    case invalidConfiguration
    case authenticationRequired
    case invalidResponse
    case server(statusCode: Int, detail: String)
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The AI service URL is not configured."
        case .authenticationRequired:
            "Your session has expired. Please sign in again to use the AI companion."
        case .invalidResponse:
            "The AI service returned an unexpected response."
        case .server(_, let detail):
            detail
        case .connectionFailed:
            "The hosted AI service is temporarily unavailable. Please wait a moment and try again."
        }
    }
}

struct ChatAPIService {
    private let authentication = SupabaseAuthService()

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

    /// Wake the free hosted service while the user is reading the Chat screen.
    /// This health request does not call Gemini or consume model quota.
    func warmUp() async {
        guard let baseURL = AppConfiguration.chatAPIBaseURL,
              baseURL.host?.hasSuffix(".onrender.com") == true else {
            return
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 75
        _ = try? await sendWithColdStartRetry(request)
    }

    func ask(
        question: String,
        weather: WeatherSnapshot?,
        transit: MBTAAlertsSnapshot? = nil,
        arrivals: MBTAArrivalsSnapshot? = nil,
        journalistAnswers: [PublishedJournalistAnswer] = [],
        history: [ChatAPIHistoryMessage] = []
    ) async throws -> ChatAPIResponse {
        guard let baseURL = AppConfiguration.chatAPIBaseURL else {
            throw ChatAPIError.invalidConfiguration
        }
        guard let accessToken = await authentication.currentAccessToken() else {
            throw ChatAPIError.authenticationRequired
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
        evidence.append(contentsOf: journalistAnswers.map(journalistEvidence))
        let body = AskRequest(
            question: question,
            location: weather?.location ?? arrivals?.queryLocation ?? transit?.scope,
            evidence: evidence,
            history: Array(history.suffix(20))
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("ask"))
        request.httpMethod = "POST"
        // Render Free can take 50 seconds or more to wake after inactivity.
        request.timeoutInterval = 75
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        var (data, httpResponse) = try await sendWithColdStartRetry(request)

        if httpResponse.statusCode == 401 {
            do {
                try await authentication.restoreSession()
                guard let refreshedToken = await authentication.currentAccessToken() else {
                    throw ChatAPIError.authenticationRequired
                }
                request.setValue(
                    "Bearer \(refreshedToken)",
                    forHTTPHeaderField: "Authorization"
                )
                (data, httpResponse) = try await sendWithColdStartRetry(request)
            } catch {
                throw ChatAPIError.authenticationRequired
            }
        }

        if httpResponse.statusCode == 401 {
            throw ChatAPIError.authenticationRequired
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

    private func sendWithColdStartRetry(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let isRenderFreeHost = request.url?.host?.hasSuffix(".onrender.com") == true
        let transientStatusCodes: Set<Int> = isRenderFreeHost
            ? [404, 502, 503, 504]
            : [502, 503, 504]

        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ChatAPIError.invalidResponse
                }

                if attempt < 2,
                   transientStatusCodes.contains(httpResponse.statusCode) {
                    try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
                    continue
                }
                return (data, httpResponse)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt == 2 {
                    throw ChatAPIError.connectionFailed
                }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 2_000_000_000)
            }
        }

        throw ChatAPIError.connectionFailed
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

        let currentConditionsLabel = weather.observationStation.map {
            "Latest station observation (\($0))"
        } ?? "Current hourly forecast"
        let evidenceText = ([
            "Location: \(weather.location)",
            "Time zone: \(weather.timeZoneIdentifier)",
            "\(currentConditionsLabel): temperature=\(weather.temperature); conditions=\(weather.summary); precipitation_chance_from_hourly_forecast=\(weather.precipitation); wind=\(weather.wind); \(weather.updatedText)",
            "Next 12 hours: \(weather.highLow)",
            "Forecast periods:"
        ] + periodLines).joined(separator: "\n")

        return Evidence(
            sourceID: "nws-forecast",
            title: "National Weather Service conditions and forecast for \(weather.location)",
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

    private func journalistEvidence(from answer: PublishedJournalistAnswer) -> Evidence {
        Evidence(
            sourceID: "journalist-response-\(answer.id.uuidString)",
            title: answer.sourceTitle,
            url: answer.sourceURL,
            text: [
                "Verified local journalist response",
                "Original community topic: \(answer.representativeQuestion)",
                "Published answer: \(answer.answerText)"
            ].joined(separator: "\n"),
            retrievedAt: answer.publishedAt
        )
    }
}
