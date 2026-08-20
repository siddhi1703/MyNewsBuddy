import CoreLocation
import Foundation

struct MBTAStopSnapshot: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let municipality: String?
    let platformName: String?
    let vehicleType: Int?
    let distanceMiles: Double

    var details: String {
        [platformName, municipality]
            .compactMap { value in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    var symbolName: String {
        switch vehicleType {
        case 0, 1: "tram.fill"
        case 2: "train.side.front.car"
        case 3: "bus.fill"
        case 4: "ferry.fill"
        default: "mappin.circle.fill"
        }
    }

    var distanceText: String {
        if distanceMiles < 0.1 {
            return "Less than 0.1 mi"
        }
        return String(format: "%.1f mi", distanceMiles)
    }
}

struct MBTAPredictionSnapshot: Identifiable {
    let id: String
    let stopID: String
    let routeID: String
    let routeName: String
    let destination: String?
    let arrivalTime: Date
    let routeColorHex: String?

    var arrivalText: String {
        let seconds = arrivalTime.timeIntervalSinceNow
        if seconds < 75 {
            return "Arriving"
        }
        return "\(max(1, Int(ceil(seconds / 60)))) min"
    }

    var clockText: String {
        arrivalTime.formatted(date: .omitted, time: .shortened)
    }
}

struct MBTAStopArrivalsSnapshot {
    let stop: MBTAStopSnapshot
    let predictions: [MBTAPredictionSnapshot]
}

struct MBTAArrivalsSnapshot {
    let queryLocation: String
    let stops: [MBTAStopArrivalsSnapshot]
    let sourceURL: URL
    let retrievedAt: Date

    var title: String {
        "MBTA live arrivals near \(queryLocation)"
    }

    var evidenceText: String {
        let formatter = ISO8601DateFormatter()
        let stopLines = stops.enumerated().flatMap { stopIndex, item in
            let stop = item.stop
            let header = [
                "Stop \(stopIndex + 1):",
                "stop_id=\(stop.id)",
                "name=\(stop.name)",
                "platform_direction=\(stop.platformName ?? "not specified")",
                "distance=\(stop.distanceText)"
            ].joined(separator: "; ")

            let predictions = item.predictions.prefix(6).enumerated().map { predictionIndex, prediction in
                [
                    "Stop \(stopIndex + 1) prediction \(predictionIndex + 1):",
                    "route=\(prediction.routeName)",
                    "route_id=\(prediction.routeID)",
                    "arrival_time=\(formatter.string(from: prediction.arrivalTime))",
                    "relative_time=\(prediction.arrivalText)",
                    "destination=\(prediction.destination ?? "not published")"
                ].joined(separator: "; ")
            }
            return [header] + predictions
        }

        return ([
            "Source: Official MBTA V3 API live predictions",
            "Search location: \(queryLocation)",
            "Times can change; distinguish each platform direction exactly as published."
        ] + stopLines).joined(separator: "\n")
    }
}

struct MBTAAlertsSnapshot {
    let scope: String
    let alerts: [MBTAAlertSnapshot]
    let sourceURL: URL
    let retrievedAt: Date

    var title: String {
        "MBTA live service alerts for \(scope)"
    }

    var evidenceText: String {
        guard !alerts.isEmpty else {
            return "The official MBTA API returned no active rider alerts for \(scope) at the retrieval time. This means only that no matching alert was published; it does not prove that all service is operating normally."
        }

        let alertText = alerts.enumerated().map { index, alert in
            [
                "Alert \(index + 1):",
                "affected_routes=\(alert.routes.isEmpty ? scope : alert.routes.joined(separator: ", "))",
                "effect=\(alert.effectName)",
                "severity=\(alert.severity)/10",
                "timeframe=\(alert.timeframe ?? "not specified")",
                "headline=\(alert.headline)",
                "details=\(alert.details ?? "not provided")",
                "updated_at=\(alert.updatedAt ?? "not provided")"
            ].joined(separator: "; ")
        }

        return ([
            "Source: Official MBTA V3 API",
            "Query scope: \(scope)",
            "Only alerts active at retrieval time are included."
        ] + alertText).joined(separator: "\n")
    }
}

struct MBTAAlertSnapshot {
    let headline: String
    let details: String?
    let effectName: String
    let severity: Int
    let timeframe: String?
    let updatedAt: String?
    let routes: [String]
}

enum MBTAServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse:
            "The MBTA returned an unexpected response. Please try again."
        case .unavailable:
            "Live MBTA data is temporarily unavailable. Please try again shortly."
        }
    }
}

struct MBTAService {
    func arrivals(
        near coordinate: CLLocationCoordinate2D,
        locationName: String,
        question: String
    ) async throws -> MBTAArrivalsSnapshot {
        let nearby = try await nearbyStops(at: coordinate)
        let normalized = question.lowercased()
        let wantsRail = [
            "green line", "red line", "orange line", "blue line",
            "silver line", "subway", "train"
        ].contains(where: normalized.contains)
        let candidateStops = nearby
            .filter { !wantsRail || $0.vehicleType == 0 || $0.vehicleType == 1 || $0.vehicleType == 2 }
            .prefix(10)

        let predictions = try await predictions(for: candidateStops.map(\.id))
        let routeTerms: [String]
        if normalized.contains("green line") {
            routeTerms = ["green"]
        } else if normalized.contains("red line") {
            routeTerms = ["red"]
        } else if normalized.contains("orange line") {
            routeTerms = ["orange"]
        } else if normalized.contains("blue line") {
            routeTerms = ["blue"]
        } else if normalized.contains("silver line") {
            routeTerms = ["silver", "741", "742", "743", "746", "749", "751"]
        } else {
            routeTerms = []
        }

        let grouped = candidateStops.compactMap { stop -> MBTAStopArrivalsSnapshot? in
            let matching = predictions.filter { prediction in
                guard prediction.stopID == stop.id else { return false }
                guard !routeTerms.isEmpty else { return true }
                let searchable = "\(prediction.routeID) \(prediction.routeName)".lowercased()
                return routeTerms.contains(where: searchable.contains)
            }
            guard !matching.isEmpty else { return nil }
            return MBTAStopArrivalsSnapshot(stop: stop, predictions: matching)
        }

        let sourceStop = grouped.first?.stop ?? candidateStops.first
        let sourceURL = sourceStop
            .flatMap { URL(string: "https://www.mbta.com/stops/\($0.id)") }
            ?? URL(string: "https://www.mbta.com/schedules")!
        return MBTAArrivalsSnapshot(
            queryLocation: locationName,
            stops: Array(grouped.prefix(4)),
            sourceURL: sourceURL,
            retrievedAt: .now
        )
    }

    func nearbyStops(
        at coordinate: CLLocationCoordinate2D,
        radius: Double = 0.02
    ) async throws -> [MBTAStopSnapshot] {
        guard var components = URLComponents(string: "https://api-v3.mbta.com/stops") else {
            throw MBTAServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "filter[latitude]", value: String(format: "%.6f", coordinate.latitude)),
            URLQueryItem(name: "filter[longitude]", value: String(format: "%.6f", coordinate.longitude)),
            URLQueryItem(name: "filter[radius]", value: String(radius)),
            URLQueryItem(name: "filter[route_type]", value: "0,1,2,3,4"),
            URLQueryItem(name: "sort", value: "distance"),
            URLQueryItem(name: "page[limit]", value: "20")
        ]

        guard let requestURL = components.url else {
            throw MBTAServiceError.invalidURL
        }

        let data = try await fetch(requestURL)
        let decoded: MBTAStopsResponse
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoded = try decoder.decode(MBTAStopsResponse.self, from: data)
        } catch {
            throw MBTAServiceError.invalidResponse
        }

        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return decoded.data.compactMap { resource in
            guard let latitude = resource.attributes.latitude,
                  let longitude = resource.attributes.longitude else {
                return nil
            }
            let stopLocation = CLLocation(latitude: latitude, longitude: longitude)
            return MBTAStopSnapshot(
                id: resource.id,
                name: resource.attributes.name,
                coordinate: stopLocation.coordinate,
                municipality: resource.attributes.municipality,
                platformName: resource.attributes.platformName,
                vehicleType: resource.attributes.vehicleType,
                distanceMiles: origin.distance(from: stopLocation) / 1_609.344
            )
        }
    }

    func predictions(for stopID: String) async throws -> [MBTAPredictionSnapshot] {
        try await predictions(for: [stopID])
    }

    func predictions(for stopIDs: [String]) async throws -> [MBTAPredictionSnapshot] {
        guard !stopIDs.isEmpty else { return [] }
        guard var components = URLComponents(string: "https://api-v3.mbta.com/predictions") else {
            throw MBTAServiceError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "filter[stop]", value: stopIDs.joined(separator: ",")),
            URLQueryItem(name: "include", value: "route,trip"),
            URLQueryItem(name: "sort", value: "time"),
            URLQueryItem(name: "page[limit]", value: "12"),
            URLQueryItem(
                name: "fields[prediction]",
                value: "arrival_time,departure_time,direction_id,status,trip_headsign"
            ),
            URLQueryItem(
                name: "fields[route]",
                value: "long_name,short_name,color,text_color"
            ),
            URLQueryItem(
                name: "fields[trip]",
                value: "headsign,direction_id"
            )
        ]

        guard let requestURL = components.url else {
            throw MBTAServiceError.invalidURL
        }

        let data = try await fetch(requestURL)
        let decoded: MBTAPredictionsResponse
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoded = try decoder.decode(MBTAPredictionsResponse.self, from: data)
        } catch {
            throw MBTAServiceError.invalidResponse
        }

        let included = decoded.included ?? []
        let routes = Dictionary(
            uniqueKeysWithValues: included
                .filter { $0.type == "route" }
                .map { ($0.id, $0.attributes) }
        )
        let trips = Dictionary(
            uniqueKeysWithValues: included
                .filter { $0.type == "trip" }
                .map { ($0.id, $0.attributes) }
        )
        let formatter = ISO8601DateFormatter()
        return decoded.data.compactMap { resource in
            let timestamp = resource.attributes.arrivalTime ?? resource.attributes.departureTime
            guard let timestamp,
                  let arrivalTime = formatter.date(from: timestamp),
                  arrivalTime > Date.now.addingTimeInterval(-90),
                  let routeID = resource.relationships.route.data?.id,
                  let stopID = resource.relationships.stop.data?.id else {
                return nil
            }

            let route = routes[routeID]
            let routeName = route?.longName ?? route?.shortName ?? routeID
            let tripID = resource.relationships.trip?.data?.id
            let destination = resource.attributes.tripHeadsign
                ?? tripID.flatMap { trips[$0]?.headsign }
            return MBTAPredictionSnapshot(
                id: resource.id,
                stopID: stopID,
                routeID: routeID,
                routeName: routeName,
                destination: destination,
                arrivalTime: arrivalTime,
                routeColorHex: route?.color
            )
        }
        .sorted { $0.arrivalTime < $1.arrivalTime }
    }

    func alerts(for question: String) async throws -> MBTAAlertsSnapshot {
        let alertQuery = Self.alertQuery(for: question)
        guard var components = URLComponents(string: "https://api-v3.mbta.com/alerts") else {
            throw MBTAServiceError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "filter[datetime]", value: "NOW"),
            URLQueryItem(name: "page[limit]", value: "12"),
            URLQueryItem(name: "sort", value: "-severity")
        ]
        if !alertQuery.routeIDs.isEmpty {
            queryItems.append(
                URLQueryItem(name: "filter[route]", value: alertQuery.routeIDs.joined(separator: ","))
            )
        } else if let routeTypes = alertQuery.routeTypes {
            queryItems.append(URLQueryItem(name: "filter[route_type]", value: routeTypes))
        }
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw MBTAServiceError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MBTAServiceError.unavailable
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw MBTAServiceError.unavailable
        }

        let decoded: MBTAAlertsResponse
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoded = try decoder.decode(MBTAAlertsResponse.self, from: data)
        } catch {
            throw MBTAServiceError.invalidResponse
        }

        let alerts = decoded.data.map { alert in
            let routes = Set(alert.attributes.informedEntity.compactMap(\.route))
            let headline = [
                alert.attributes.header,
                alert.attributes.shortHeader,
                alert.attributes.serviceEffect
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "Active MBTA service alert"

            return MBTAAlertSnapshot(
                headline: headline,
                details: Self.shortened(alert.attributes.description),
                effectName: alert.attributes.effectName ?? alert.attributes.effect ?? "Service alert",
                severity: alert.attributes.severity ?? 0,
                timeframe: alert.attributes.timeframe,
                updatedAt: alert.attributes.updatedAt,
                routes: routes.sorted()
            )
        }

        return MBTAAlertsSnapshot(
            scope: alertQuery.label,
            alerts: alerts,
            sourceURL: URL(string: "https://www.mbta.com/alerts")!,
            retrievedAt: .now
        )
    }

    private static func shortened(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        guard text.count > 600 else { return text }
        return String(text.prefix(600)) + "…"
    }

    private static func alertQuery(for question: String) -> AlertQuery {
        let normalized = question.lowercased()
        let namedRoutes: [(terms: [String], ids: [String], label: String)] = [
            (["green line", "green-line"], ["Green-B", "Green-C", "Green-D", "Green-E"], "the Green Line"),
            (["red line", "red-line"], ["Red"], "the Red Line"),
            (["orange line", "orange-line"], ["Orange"], "the Orange Line"),
            (["blue line", "blue-line"], ["Blue"], "the Blue Line"),
            (["mattapan line", "mattapan trolley"], ["Mattapan"], "the Mattapan Line"),
            (["silver line", "silver-line"], ["741", "742", "743", "746", "749", "751"], "the Silver Line")
        ]

        if let route = namedRoutes.first(where: { candidate in
            candidate.terms.contains { normalized.contains($0) }
        }) {
            return AlertQuery(routeIDs: route.ids, routeTypes: nil, label: route.label)
        }

        if let busRoute = firstMatch(in: normalized, pattern: #"\b(?:bus|route)\s*#?\s*(\d{1,3})\b"#) {
            return AlertQuery(routeIDs: [busRoute], routeTypes: nil, label: "MBTA bus route \(busRoute)")
        }

        if normalized.contains("commuter rail") {
            return AlertQuery(routeIDs: [], routeTypes: "2", label: "MBTA Commuter Rail")
        }
        if normalized.contains("ferry") {
            return AlertQuery(routeIDs: [], routeTypes: "4", label: "MBTA ferry service")
        }
        if normalized.contains("bus") {
            return AlertQuery(routeIDs: [], routeTypes: "3", label: "MBTA bus service")
        }

        return AlertQuery(routeIDs: [], routeTypes: "0,1", label: "MBTA subway service")
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private struct AlertQuery {
        let routeIDs: [String]
        let routeTypes: String?
        let label: String
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw MBTAServiceError.unavailable
            }
            return data
        } catch let error as MBTAServiceError {
            throw error
        } catch {
            throw MBTAServiceError.unavailable
        }
    }
}

private struct MBTAStopsResponse: Decodable {
    let data: [StopResource]

    struct StopResource: Decodable {
        let id: String
        let attributes: Attributes
    }

    struct Attributes: Decodable {
        let latitude: Double?
        let longitude: Double?
        let municipality: String?
        let name: String
        let platformName: String?
        let vehicleType: Int?
    }
}

private struct MBTAPredictionsResponse: Decodable {
    let data: [PredictionResource]
    let included: [RouteResource]?

    struct PredictionResource: Decodable {
        let id: String
        let attributes: Attributes
        let relationships: Relationships
    }

    struct Attributes: Decodable {
        let arrivalTime: String?
        let departureTime: String?
        let directionId: Int?
        let status: String?
        let tripHeadsign: String?
    }

    struct Relationships: Decodable {
        let route: Relationship
        let stop: Relationship
        let trip: Relationship?
    }

    struct Relationship: Decodable {
        let data: ResourceIdentifier?
    }

    struct ResourceIdentifier: Decodable {
        let id: String
    }

    struct RouteResource: Decodable {
        let id: String
        let type: String
        let attributes: RouteAttributes
    }

    struct RouteAttributes: Decodable {
        let longName: String?
        let shortName: String?
        let color: String?
        let textColor: String?
        let headsign: String?
        let directionId: Int?
    }
}

private struct MBTAAlertsResponse: Decodable {
    let data: [AlertResource]

    struct AlertResource: Decodable {
        let attributes: Attributes
    }

    struct Attributes: Decodable {
        let description: String?
        let effect: String?
        let effectName: String?
        let header: String?
        let informedEntity: [InformedEntity]
        let serviceEffect: String?
        let severity: Int?
        let shortHeader: String?
        let timeframe: String?
        let updatedAt: String?
    }

    struct InformedEntity: Decodable {
        let route: String?
    }
}
