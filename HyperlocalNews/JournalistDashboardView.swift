import SwiftUI

struct InformationGapCluster: Decodable, Identifiable {
    let clusterID: UUID
    let representativeQuestion: String
    let category: String
    let status: String
    let questionCount: Int
    let uniqueAskerCount: Int
    let locations: [String]
    let questionExamples: [String]
    let firstSeenAt: Date
    let lastSeenAt: Date

    var id: UUID { clusterID }

    enum CodingKeys: String, CodingKey {
        case clusterID = "cluster_id"
        case representativeQuestion = "representative_question"
        case category
        case status
        case questionCount = "question_count"
        case uniqueAskerCount = "unique_asker_count"
        case locations
        case questionExamples = "question_examples"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct JournalistGapSummary: Decodable {
    let topicCount: Int
    let questionCount: Int
    let uniqueAskerCount: Int

    enum CodingKeys: String, CodingKey {
        case topicCount = "topic_count"
        case questionCount = "question_count"
        case uniqueAskerCount = "unique_asker_count"
    }

    static let empty = JournalistGapSummary(
        topicCount: 0,
        questionCount: 0,
        uniqueAskerCount: 0
    )
}

enum JournalistDashboardError: LocalizedError {
    case signedOut
    case invalidResponse
    case accessRequired
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut:
            "Sign in again to open the journalist workspace."
        case .invalidResponse:
            "Supabase returned an unexpected journalist-dashboard response."
        case .accessRequired:
            "This account does not have journalist access."
        case .server(let message):
            message
        }
    }
}

actor JournalistGapService {
    private let authentication = SupabaseAuthService()

    func hasJournalistAccess() async -> Bool {
        do {
            let data = try await callRPC(path: "is_journalist", body: Data("{}".utf8))
            return (try? JSONDecoder().decode(Bool.self, from: data)) == true
        } catch {
            return false
        }
    }

    func fetchClusters(minimumQuestions: Int = 1) async throws -> [InformationGapCluster] {
        guard await hasJournalistAccess() else {
            throw JournalistDashboardError.accessRequired
        }

        let body = try JSONEncoder().encode(
            ClusterRequest(minimumQuestions: max(minimumQuestions, 1))
        )
        let data = try await callRPC(path: "get_information_gap_clusters", body: body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }
            if let date = ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid Supabase timestamp."
            )
        }

        do {
            return try decoder.decode([InformationGapCluster].self, from: data)
        } catch {
            throw JournalistDashboardError.invalidResponse
        }
    }

    func fetchSummary() async throws -> JournalistGapSummary {
        guard await hasJournalistAccess() else {
            throw JournalistDashboardError.accessRequired
        }
        let data = try await callRPC(
            path: "get_information_gap_summary",
            body: Data("{}".utf8)
        )
        do {
            return try JSONDecoder().decode(JournalistGapSummary.self, from: data)
        } catch {
            throw JournalistDashboardError.invalidResponse
        }
    }

    private func callRPC(path: String, body: Data) async throws -> Data {
        let configuration: AuthConfiguration
        do {
            configuration = try AuthConfiguration.load()
        } catch {
            throw JournalistDashboardError.server(error.localizedDescription)
        }

        guard let accessToken = await authentication.currentAccessToken() else {
            throw JournalistDashboardError.signedOut
        }

        let endpoint = configuration.projectURL.appending(path: "rest/v1/rpc/\(path)")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JournalistDashboardError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw JournalistDashboardError.accessRequired
            }
            let apiError = try? JSONDecoder().decode(DashboardAPIError.self, from: data)
            throw JournalistDashboardError.server(
                apiError?.message ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
        return data
    }
}

private struct ClusterRequest: Encodable {
    let minimumQuestions: Int

    enum CodingKeys: String, CodingKey {
        case minimumQuestions = "minimum_questions"
    }
}

private struct DashboardAPIError: Decodable {
    let message: String?
}

@MainActor
private final class JournalistDashboardModel: ObservableObject {
    @Published var clusters: [InformationGapCluster] = []
    @Published var summary = JournalistGapSummary.empty
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service = JournalistGapService()

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loadedClusters = try await service.fetchClusters()
            clusters = loadedClusters
            do {
                summary = try await service.fetchSummary()
            } catch {
                // Keep the inbox usable while an older database is waiting for
                // the summary migration. The RPC becomes the authoritative
                // distinct-user count as soon as that migration is installed.
                summary = JournalistGapSummary(
                    topicCount: loadedClusters.count,
                    questionCount: loadedClusters.reduce(0) { $0 + $1.questionCount },
                    uniqueAskerCount: loadedClusters.reduce(0) { $0 + $1.uniqueAskerCount }
                )
            }
        } catch {
            clusters = []
            summary = .empty
            errorMessage = error.localizedDescription
        }
    }
}

struct JournalistDashboardView: View {
    @StateObject private var model = JournalistDashboardModel()
    @State private var presentedSheet: JournalistDashboardSheet?

    var body: some View {
        Group {
            if model.isLoading && model.clusters.isEmpty {
                ProgressView("Loading community information gaps…")
            } else if let errorMessage = model.errorMessage, model.clusters.isEmpty {
                ContentUnavailableView(
                    "Journalist inbox unavailable",
                    systemImage: "exclamationmark.bubble",
                    description: Text(errorMessage)
                )
            } else if model.clusters.isEmpty {
                ContentUnavailableView(
                    "No information gaps yet",
                    systemImage: "checkmark.bubble",
                    description: Text("New genuine civic gaps will appear here after community members ask them.")
                )
            } else {
                List {
                    Section {
                        HStack {
                            Button {
                                presentedSheet = .summary(.topics)
                            } label: {
                                JournalistMetric(
                                    value: "\(model.summary.topicCount)",
                                    label: "Topics",
                                    color: .purple
                                )
                            }
                            Button {
                                presentedSheet = .summary(.questions)
                            } label: {
                                JournalistMetric(
                                    value: "\(model.summary.questionCount)",
                                    label: "Questions",
                                    color: .orange
                                )
                            }
                            Button {
                                presentedSheet = .summary(.askers)
                            } label: {
                                JournalistMetric(
                                    value: "\(model.summary.uniqueAskerCount)",
                                    label: "Askers",
                                    color: .blue
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                    } header: {
                        Text("Community signal")
                    }

                    Section("Information-gap clusters") {
                        ForEach(model.clusters) { cluster in
                            Button {
                                presentedSheet = .cluster(cluster)
                            } label: {
                                HStack(spacing: 10) {
                                    JournalistClusterRow(cluster: cluster)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open topic: \(cluster.representativeQuestion)")
                            .accessibilityHint("Shows the reporting lead, locations, question examples, and timeline")
                        }
                    }
                }
                .refreshable { await model.load() }
            }
        }
        .navigationTitle("Journalist Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                .accessibilityLabel("Refresh journalist inbox")
            }
        }
        .task { await model.load() }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .cluster(let cluster):
                JournalistClusterDetailSheet(cluster: cluster)
            case .summary(let metric):
                JournalistSummaryDetailView(
                    metric: metric,
                    summary: model.summary,
                    clusters: model.clusters
                )
            }
        }
    }
}

private enum JournalistSummaryMetric: String, Identifiable {
    case topics
    case questions
    case askers

    var id: String { rawValue }
}

private enum JournalistDashboardSheet: Identifiable {
    case cluster(InformationGapCluster)
    case summary(JournalistSummaryMetric)

    var id: String {
        switch self {
        case .cluster(let cluster):
            "cluster-\(cluster.id.uuidString)"
        case .summary(let metric):
            "summary-\(metric.rawValue)"
        }
    }
}

private struct JournalistMetric: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct JournalistClusterRow: View {
    let cluster: InformationGapCluster

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cluster.representativeQuestion)
                .font(.headline)
                .lineLimit(3)

            HStack(spacing: 8) {
                Label("\(cluster.questionCount)", systemImage: "bubble.left.and.bubble.right.fill")
                Label("\(cluster.uniqueAskerCount)", systemImage: "person.2.fill")
                Spacer()
                Text(cluster.category.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            HStack {
                Text(cluster.status.capitalized)
                    .font(.caption2.bold())
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.purple.opacity(0.1), in: Capsule())
                Spacer()
                Text(cluster.lastSeenAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct JournalistClusterDetailView: View {
    let cluster: InformationGapCluster

    var body: some View {
        List {
            Section("Reporting lead") {
                Text(cluster.representativeQuestion)
                    .font(.headline)
                LabeledContent("Category", value: cluster.category.replacingOccurrences(of: "_", with: " ").capitalized)
                LabeledContent("Status", value: cluster.status.capitalized)
                LabeledContent("Questions", value: "\(cluster.questionCount)")
                LabeledContent("Unique askers", value: "\(cluster.uniqueAskerCount)")
            }

            Section("Locations") {
                ForEach(cluster.locations, id: \.self) { location in
                    Label(location, systemImage: "mappin.and.ellipse")
                }
            }

            Section("Example community questions") {
                ForEach(cluster.questionExamples, id: \.self) { question in
                    Text(question)
                }
            }

            Section("Timeline") {
                LabeledContent("First asked") {
                    Text(cluster.firstSeenAt, style: .date)
                }
                LabeledContent("Most recent") {
                    Text(cluster.lastSeenAt, style: .relative)
                }
            }

            Section {
                Text("This is a reporting lead, not a verified story. A journalist must review the premise and supporting evidence before publication.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Gap details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct JournalistClusterDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let cluster: InformationGapCluster

    var body: some View {
        NavigationStack {
            JournalistClusterDetailView(cluster: cluster)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private struct JournalistSummaryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let metric: JournalistSummaryMetric
    let summary: JournalistGapSummary
    let clusters: [InformationGapCluster]

    var body: some View {
        NavigationStack {
            List {
                switch metric {
                case .topics:
                    Section("Active reporting topics") {
                        ForEach(clusters) { cluster in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cluster.representativeQuestion)
                                    .font(.headline)
                                Text(cluster.category.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }

                case .questions:
                    ForEach(clusters) { cluster in
                        Section(cluster.representativeQuestion) {
                            ForEach(Array(cluster.questionExamples.enumerated()), id: \.offset) { _, question in
                                Text(question)
                            }
                        }
                    }

                case .askers:
                    Section {
                        LabeledContent("Distinct community askers", value: "\(summary.uniqueAskerCount)")
                    } footer: {
                        Text("Names and email addresses are intentionally hidden to protect community members.")
                    }

                    Section("Participation by topic") {
                        ForEach(clusters) { cluster in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(cluster.representativeQuestion)
                                Label(
                                    "\(cluster.uniqueAskerCount) unique asker\(cluster.uniqueAskerCount == 1 ? "" : "s")",
                                    systemImage: "person.2.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var title: String {
        switch metric {
        case .topics: "Topics (\(summary.topicCount))"
        case .questions: "Questions (\(summary.questionCount))"
        case .askers: "Askers (\(summary.uniqueAskerCount))"
        }
    }
}
