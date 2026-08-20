import CoreLocation
import MapKit
import SwiftUI

struct TransitMapView: View {
    @ObservedObject var weatherModel: WeatherViewModel
    @StateObject private var mapModel = TransitMapViewModel()
    @State private var waitingForCurrentLocation = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.90, green: 0.96, blue: 1.00),
                        Color(red: 0.96, green: 0.92, blue: 1.00),
                        Color(red: 1.00, green: 0.95, blue: 0.88)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        intro
                        searchCard
                        mapCard
                        resultsCard
                        sourceNote
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Transit Map")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard !mapModel.hasLoaded else { return }
                if let coordinate = weatherModel.mapCoordinate {
                    await mapModel.loadStops(
                        at: coordinate,
                        locationName: weatherModel.weather.location
                    )
                    mapModel.originText = "Current location"
                } else {
                    await mapModel.search(for: "Boston, MA")
                }
            }
            .onChange(of: weatherModel.mapCoordinate?.latitude) { _, _ in
                guard waitingForCurrentLocation,
                      let coordinate = weatherModel.mapCoordinate else { return }
                waitingForCurrentLocation = false
                Task {
                    await mapModel.loadStops(
                        at: coordinate,
                        locationName: weatherModel.weather.location
                    )
                    mapModel.originText = "Current location"
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Find your next ride")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Choose where you’re starting and where you want to go. Then see the transit route and live MBTA arrivals.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var searchCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "location.fill")
                    .foregroundStyle(Color(red: 0.35, green: 0.25, blue: 0.88))
                    .frame(width: 22)

                TextField("Your location", text: $mapModel.originText)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)

                Button {
                    useCurrentLocation()
                } label: {
                    Image(systemName: "location.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color(red: 0.35, green: 0.25, blue: 0.88))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use my current location")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))

            HStack(spacing: 10) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.pink)
                    .frame(width: 22)

                TextField("Your destination", text: $mapModel.destinationText)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.go)
                    .onSubmit {
                        Task { await mapModel.planRoute() }
                    }

                if !mapModel.destinationText.isEmpty {
                    Button {
                        mapModel.destinationText = ""
                        mapModel.clearRoute()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear destination")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))

            Button {
                Task { await mapModel.planRoute() }
            } label: {
                HStack {
                    if mapModel.isLoadingRoute {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    }
                    Text(mapModel.isLoadingRoute ? "Finding locations…" : "Find transit options")
                        .fontWeight(.bold)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 17)
                )
            }
            .buttonStyle(.plain)
            .disabled(
                mapModel.destinationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || mapModel.isLoadingRoute
            )
            .opacity(mapModel.destinationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)

            Label(mapModel.locationName, systemImage: "scope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var mapCard: some View {
        Map(position: $mapModel.cameraPosition) {
            UserAnnotation()

            if let coordinate = mapModel.focusCoordinate {
                Marker(
                    mapModel.locationName,
                    systemImage: "mappin.and.ellipse",
                    coordinate: coordinate
                )
                .tint(Color(red: 0.49, green: 0.25, blue: 0.92))
            }

            if let destinationCoordinate = mapModel.destinationCoordinate {
                Marker(
                    mapModel.destinationName,
                    systemImage: "flag.checkered",
                    coordinate: destinationCoordinate
                )
                .tint(.pink)
            }

            ForEach(mapModel.stops) { stop in
                Annotation(stop.name, coordinate: stop.coordinate, anchor: .bottom) {
                    Button {
                        Task { await mapModel.select(stop) }
                    } label: {
                        Image(systemName: stop.symbolName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(markerColor(for: stop), in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(stop.name), \(stop.distanceText)")
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapScaleView()
            MapUserLocationButton()
        }
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(.white.opacity(0.75), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 7) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("LIVE MBTA")
                    .font(.caption2.weight(.heavy))
                    .tracking(0.8)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(12)
        }
    }

    @ViewBuilder
    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if mapModel.isLoadingRoute {
                loadingRow("Finding your start and destination…")
                Divider()
            } else if mapModel.routeIsReady {
                routeSummary
                Divider()
            }

            if mapModel.isLoadingStops {
                loadingRow("Finding nearby MBTA stops…")
            } else if let errorMessage = mapModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else if let selectedStop = mapModel.selectedStop {
                selectedStopHeader(selectedStop)
                Divider()

                if mapModel.isLoadingPredictions {
                    loadingRow("Loading live arrivals…")
                } else if mapModel.predictions.isEmpty {
                    Text("No live predictions are published for this stop right now. Try refresh or choose another marker.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mapModel.predictions.prefix(8)) { prediction in
                        predictionRow(prediction)
                        if prediction.id != mapModel.predictions.prefix(8).last?.id {
                            Divider()
                        }
                    }
                }
            } else if mapModel.stops.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No MBTA stops found nearby", systemImage: "map.fill")
                        .font(.headline)
                    Text("MBTA data covers Greater Boston. Search a Boston-area address such as “390 Riverway, Boston, MA.”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nearby stops")
                            .font(.title3.bold())
                        Text("Tap a row or a map marker for arrivals")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(mapModel.stops.count)")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.49, green: 0.25, blue: 0.92))
                }

                ForEach(mapModel.stops.prefix(8)) { stop in
                    Button {
                        Task { await mapModel.select(stop) }
                    } label: {
                        stopRow(stop)
                    }
                    .buttonStyle(.plain)

                    if stop.id != mapModel.stops.prefix(8).last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.90), in: RoundedRectangle(cornerRadius: 26))
    }

    private var routeSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        LinearGradient(
                            colors: [.orange, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 15)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Locations ready")
                        .font(.headline)
                    Text("Open Apple Maps to compare live public-transit options and departure times.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                mapModel.openTransitDirections()
            } label: {
                Label("Open transit directions", systemImage: "map.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color(red: 0.35, green: 0.25, blue: 0.88), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private func selectedStopHeader(_ stop: MBTAStopSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: stop.symbolName)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(markerColor(for: stop), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(stop.name)
                    .font(.headline)
                Text([stop.details, stop.distanceText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await mapModel.refreshPredictions() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .accessibilityLabel("Refresh arrivals")
        }
    }

    private func stopRow(_ stop: MBTAStopSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: stop.symbolName)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(markerColor(for: stop), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(stop.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(stop.details.isEmpty ? stop.distanceText : "\(stop.details) · \(stop.distanceText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func predictionRow(_ prediction: MBTAPredictionSnapshot) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(routeColor(for: prediction))
                .frame(width: 7, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(prediction.routeName)
                    .font(.subheadline.weight(.bold))
                if let destination = prediction.destination, !destination.isEmpty {
                    Text("Toward \(destination)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(prediction.arrivalText)
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.43, green: 0.22, blue: 0.86))
                Text(prediction.clockText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var sourceNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Map by Apple · Live transit data by MBTA", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.semibold))
            Text("Arrival times are live predictions and can change. No Google Maps billing or Google API key is used.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let stop = mapModel.selectedStop,
               let url = URL(string: "https://www.mbta.com/stops/\(stop.id)") {
                Link("Open this stop on MBTA.com", destination: url)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 4)
    }

    private func useCurrentLocation() {
        if weatherModel.isUsingCurrentLocation,
           let coordinate = weatherModel.mapCoordinate {
            Task {
                await mapModel.loadStops(
                    at: coordinate,
                    locationName: weatherModel.weather.location
                )
                mapModel.originText = "Current location"
            }
        } else {
            // `mapCoordinate` can represent a manually selected weather city.
            // Do not mistake that city for the phone's current GPS location.
            waitingForCurrentLocation = true
            weatherModel.useCurrentLocation()
            mapModel.errorMessage = "Finding your current location…"
        }
    }

    private func markerColor(for stop: MBTAStopSnapshot) -> Color {
        switch stop.vehicleType {
        case 0, 1: Color(red: 0.00, green: 0.52, blue: 0.25)
        case 2: Color(red: 0.50, green: 0.25, blue: 0.62)
        case 3: Color(red: 0.16, green: 0.43, blue: 0.78)
        case 4: Color(red: 0.10, green: 0.60, blue: 0.70)
        default: Color(red: 0.49, green: 0.25, blue: 0.92)
        }
    }

    private func routeColor(for prediction: MBTAPredictionSnapshot) -> Color {
        guard let hex = prediction.routeColorHex,
              let value = Int(hex, radix: 16) else {
            return Color(red: 0.49, green: 0.25, blue: 0.92)
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

@MainActor
private final class TransitMapViewModel: ObservableObject {
    @Published var originText = "Current location"
    @Published var destinationText = ""
    @Published var locationName = "Boston, MA"
    @Published var focusCoordinate: CLLocationCoordinate2D?
    @Published var destinationCoordinate: CLLocationCoordinate2D?
    @Published var destinationName = "Destination"
    @Published var routeIsReady = false
    @Published var stops: [MBTAStopSnapshot] = []
    @Published var selectedStop: MBTAStopSnapshot?
    @Published var predictions: [MBTAPredictionSnapshot] = []
    @Published var isLoadingStops = false
    @Published var isLoadingPredictions = false
    @Published var isLoadingRoute = false
    @Published var errorMessage: String?
    @Published var cameraPosition: MapCameraPosition = .automatic

    private let service = MBTAService()
    private var routeOriginItem: MKMapItem?
    private var routeDestinationItem: MKMapItem?
    private(set) var hasLoaded = false

    func search(for query: String) async {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        isLoadingStops = true
        errorMessage = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = value
        request.resultTypes = [.address, .pointOfInterest]

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else {
                isLoadingStops = false
                errorMessage = "That place could not be found. Try adding the city and state."
                return
            }
            let placemark = item.placemark
            let name = locationLabel(for: item)
            originText = name
            await loadStops(at: placemark.coordinate, locationName: name)
        } catch {
            isLoadingStops = false
            errorMessage = "That place could not be found. Check the spelling and try again."
        }
    }

    func planRoute() async {
        let originQuery = originText.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationQuery = destinationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destinationQuery.isEmpty else {
            errorMessage = "Enter where you want to go."
            return
        }

        isLoadingRoute = true
        errorMessage = nil
        selectedStop = nil
        predictions = []

        do {
            let originItem: MKMapItem
            if originQuery.isEmpty || originQuery.lowercased() == "current location" {
                guard let focusCoordinate else {
                    isLoadingRoute = false
                    errorMessage = "Your current location is not ready yet. Tap the location button and try again."
                    return
                }
                originItem = MKMapItem(placemark: MKPlacemark(coordinate: focusCoordinate))
            } else {
                originItem = try await mapItem(for: originQuery, near: focusCoordinate)
            }

            let originCoordinate = originItem.placemark.coordinate
            let destinationItem = try await mapItem(
                for: destinationQuery,
                near: originCoordinate
            )
            let resolvedOriginName = originQuery.lowercased() == "current location"
                ? locationName
                : locationLabel(for: originItem)
            let resolvedDestinationName = locationLabel(for: destinationItem)

            focusCoordinate = originCoordinate
            locationName = resolvedOriginName
            destinationCoordinate = destinationItem.placemark.coordinate
            destinationName = resolvedDestinationName
            destinationText = resolvedDestinationName
            isLoadingStops = true
            routeOriginItem = originItem
            routeDestinationItem = destinationItem
            routeIsReady = true

            let originPoint = MKMapPoint(originCoordinate)
            let destinationPoint = MKMapPoint(destinationItem.placemark.coordinate)
            let rect = MKMapRect(
                x: min(originPoint.x, destinationPoint.x),
                y: min(originPoint.y, destinationPoint.y),
                width: max(1, abs(originPoint.x - destinationPoint.x)),
                height: max(1, abs(originPoint.y - destinationPoint.y))
            )
            cameraPosition = .rect(
                rect.insetBy(
                    dx: -max(900, rect.size.width * 0.20),
                    dy: -max(900, rect.size.height * 0.20)
                )
            )
            isLoadingRoute = false

            do {
                stops = try await service.nearbyStops(at: originCoordinate)
            } catch {
                stops = []
            }
            isLoadingStops = false
        } catch {
            routeIsReady = false
            routeOriginItem = nil
            routeDestinationItem = nil
            destinationCoordinate = nil
            isLoadingRoute = false
            isLoadingStops = false
            errorMessage = "I couldn’t match one of those locations. Try complete addresses such as “390 Riverway, Boston, MA.”"
        }
    }

    func clearRoute() {
        routeIsReady = false
        routeOriginItem = nil
        routeDestinationItem = nil
        destinationCoordinate = nil
        destinationName = "Destination"
        errorMessage = nil
        if let focusCoordinate {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: focusCoordinate,
                    latitudinalMeters: 3_500,
                    longitudinalMeters: 3_500
                )
            )
        }
    }

    func openTransitDirections() {
        guard let routeOriginItem, let routeDestinationItem else { return }
        MKMapItem.openMaps(
            with: [routeOriginItem, routeDestinationItem],
            launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit
            ]
        )
    }

    func loadStops(at coordinate: CLLocationCoordinate2D, locationName: String) async {
        hasLoaded = true
        isLoadingStops = true
        errorMessage = nil
        selectedStop = nil
        predictions = []
        routeIsReady = false
        routeOriginItem = nil
        routeDestinationItem = nil
        destinationCoordinate = nil
        destinationName = "Destination"
        focusCoordinate = coordinate
        self.locationName = locationName.isEmpty ? "Selected area" : locationName
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 3_500,
                longitudinalMeters: 3_500
            )
        )

        do {
            stops = try await service.nearbyStops(at: coordinate)
            isLoadingStops = false
        } catch {
            stops = []
            isLoadingStops = false
            errorMessage = error.localizedDescription
        }
    }

    func select(_ stop: MBTAStopSnapshot) async {
        selectedStop = stop
        predictions = []
        cameraPosition = .region(
            MKCoordinateRegion(
                center: stop.coordinate,
                latitudinalMeters: 1_400,
                longitudinalMeters: 1_400
            )
        )
        await refreshPredictions()
    }

    func refreshPredictions() async {
        guard let selectedStop else { return }
        isLoadingPredictions = true
        errorMessage = nil
        do {
            predictions = try await service.predictions(for: selectedStop.id)
            isLoadingPredictions = false
        } catch {
            predictions = []
            isLoadingPredictions = false
            errorMessage = error.localizedDescription
        }
    }

    private func mapItem(
        for query: String,
        near coordinate: CLLocationCoordinate2D?
    ) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        let normalized = " \(query.lowercased()) "
        let explicitPlaceTerms = [
            ",", " boston ", " massachusetts ", " ma ", " brookline ",
            " cambridge ", " somerville ", " newton ", " quincy ",
            " medford ", " san francisco ", " california ", " ca "
        ]
        let hasExplicitPlace = explicitPlaceTerms.contains(where: normalized.contains)

        // Only bias ambiguous searches such as “Northeastern University.” An
        // explicit “Boston” query must not inherit a Simulator location in SF.
        if let coordinate, !hasExplicitPlace {
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 40_000,
                longitudinalMeters: 40_000
            )
        }
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw TransitRouteError.placeNotFound
        }
        return item
    }

    private func locationLabel(for item: MKMapItem) -> String {
        let placemark = item.placemark
        let place = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let locality = placemark.locality
        let state = placemark.administrativeArea

        let cityState = [locality, state]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        if let place, !place.isEmpty, place != locality {
            return cityState.isEmpty ? place : "\(place) · \(cityState)"
        }
        return cityState.isEmpty ? "Selected area" : cityState
    }
}

private enum TransitRouteError: Error {
    case placeNotFound
}
