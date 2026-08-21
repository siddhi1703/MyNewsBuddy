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

struct JournalistResponseDraft: Decodable {
    let responseID: UUID
    let responseText: String
    let sourceTitle: String
    let sourceURL: URL
    let responseStatus: String
    let updatedAt: String
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case responseID = "response_id"
        case responseText = "response_text"
        case sourceTitle = "source_title"
        case sourceURL = "source_url"
        case responseStatus = "response_status"
        case updatedAt = "updated_at"
        case publishedAt = "published_at"
    }
}

struct CommunityJournalistResponse: Decodable, Identifiable {
    let notificationID: UUID
    let clusterID: UUID
    let originalQuestion: String
    let answerText: String
    let sourceTitle: String
    let sourceURL: URL
    let publishedAt: String
    let readAt: String?

    var id: UUID { notificationID }
    var isUnread: Bool { readAt == nil }

    enum CodingKeys: String, CodingKey {
        case notificationID = "notification_id"
        case clusterID = "cluster_id"
        case originalQuestion = "original_question"
        case answerText = "answer_text"
        case sourceTitle = "source_title"
        case sourceURL = "source_url"
        case publishedAt = "published_at"
        case readAt = "read_at"
    }
}

struct PublishedJournalistAnswer: Decodable, Identifiable {
    let responseID: UUID
    let representativeQuestion: String
    let answerText: String
    let sourceTitle: String
    let sourceURL: URL
    let publishedAt: String
    let similarityScore: Double

    var id: UUID { responseID }

    enum CodingKeys: String, CodingKey {
        case responseID = "response_id"
        case representativeQuestion = "representative_question"
        case answerText = "answer_text"
        case sourceTitle = "source_title"
        case sourceURL = "source_url"
        case publishedAt = "published_at"
        case similarityScore = "similarity_score"
    }
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

    func fetchResponse(for clusterID: UUID) async throws -> JournalistResponseDraft? {
        guard await hasJournalistAccess() else {
            throw JournalistDashboardError.accessRequired
        }
        let body = try JSONEncoder().encode(ClusterIDRequest(clusterID: clusterID))
        let data = try await callRPC(path: "get_journalist_response", body: body)
        do {
            return try JSONDecoder().decode([JournalistResponseDraft].self, from: data).first
        } catch {
            throw JournalistDashboardError.invalidResponse
        }
    }

    func saveResponse(
        clusterID: UUID,
        answer: String,
        sourceTitle: String,
        sourceURL: URL,
        publish: Bool
    ) async throws {
        guard await hasJournalistAccess() else {
            throw JournalistDashboardError.accessRequired
        }
        let body = try JSONEncoder().encode(
            SaveResponseRequest(
                clusterID: clusterID,
                answer: answer,
                sourceTitle: sourceTitle,
                sourceURL: sourceURL.absoluteString,
                publish: publish
            )
        )
        _ = try await callRPC(path: "save_journalist_response", body: body)
    }

    func dismiss(clusterID: UUID, reason: String) async throws {
        guard await hasJournalistAccess() else {
            throw JournalistDashboardError.accessRequired
        }
        let body = try JSONEncoder().encode(
            DismissClusterRequest(clusterID: clusterID, reason: reason)
        )
        _ = try await callRPC(path: "dismiss_information_gap", body: body)
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

actor CommunityResponseService {
    private let authentication = SupabaseAuthService()

    func notifications() async throws -> [CommunityJournalistResponse] {
        let data = try await callRPC(
            path: "get_my_journalist_notifications",
            body: Data("{}".utf8)
        )
        do {
            return try JSONDecoder().decode([CommunityJournalistResponse].self, from: data)
        } catch {
            throw JournalistDashboardError.invalidResponse
        }
    }

    func markRead(_ notificationID: UUID) async throws {
        let body = try JSONEncoder().encode(
            NotificationIDRequest(notificationID: notificationID)
        )
        _ = try await callRPC(path: "mark_journalist_notification_read", body: body)
    }

    func searchPublishedAnswers(for question: String) async throws -> [PublishedJournalistAnswer] {
        let body = try JSONEncoder().encode(
            PublishedAnswerSearchRequest(question: question, threshold: 0.35)
        )
        let data = try await callRPC(
            path: "search_published_journalist_answers",
            body: body
        )
        do {
            return try JSONDecoder().decode([PublishedJournalistAnswer].self, from: data)
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

private struct ClusterIDRequest: Encodable {
    let clusterID: UUID

    enum CodingKeys: String, CodingKey {
        case clusterID = "target_cluster_id"
    }
}

private struct SaveResponseRequest: Encodable {
    let clusterID: UUID
    let answer: String
    let sourceTitle: String
    let sourceURL: String
    let publish: Bool

    enum CodingKeys: String, CodingKey {
        case clusterID = "target_cluster_id"
        case answer = "answer_text"
        case sourceTitle = "answer_source_title"
        case sourceURL = "answer_source_url"
        case publish
    }
}

private struct DismissClusterRequest: Encodable {
    let clusterID: UUID
    let reason: String

    enum CodingKeys: String, CodingKey {
        case clusterID = "target_cluster_id"
        case reason
    }
}

private struct NotificationIDRequest: Encodable {
    let notificationID: UUID

    enum CodingKeys: String, CodingKey {
        case notificationID = "target_notification_id"
    }
}

private struct PublishedAnswerSearchRequest: Encodable {
    let question: String
    let threshold: Double

    enum CodingKeys: String, CodingKey {
        case question = "query_text"
        case threshold = "match_threshold"
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
                JournalistClusterDetailSheet(cluster: cluster) {
                    Task { await model.load() }
                }
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

private struct JournalistClusterDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let cluster: InformationGapCluster
    let onChanged: () -> Void

    @State private var answer = ""
    @State private var sourceTitle = ""
    @State private var sourceURL = ""
    @State private var isLoadingDraft = false
    @State private var isSaving = false
    @State private var isPublished = false
    @State private var feedbackMessage: String?
    @State private var errorMessage: String?
    @State private var isConfirmingDismissal = false

    private let service = JournalistGapService()

    var body: some View {
        NavigationStack {
            List {
                Section("Reporting lead") {
                    Text(cluster.representativeQuestion)
                        .font(.headline)
                    LabeledContent("Category", value: displayCategory)
                    LabeledContent("Status", value: cluster.status.capitalized)
                    LabeledContent("Questions", value: "\(cluster.questionCount)")
                    LabeledContent("Unique askers", value: "\(cluster.uniqueAskerCount)")
                }

                Section("Example community questions") {
                    ForEach(cluster.questionExamples, id: \.self) { question in
                        Text(question)
                    }
                }

                if !cluster.locations.isEmpty {
                    Section("Locations") {
                        ForEach(cluster.locations, id: \.self) { location in
                            Label(location, systemImage: "mappin.and.ellipse")
                        }
                    }
                }

                Section {
                    if isLoadingDraft {
                        ProgressView("Loading saved draft…")
                    }

                    TextEditor(text: $answer)
                        .frame(minHeight: 130)
                        .accessibilityLabel("Verified journalist answer")

                    TextField("Source title", text: $sourceTitle)
                    TextField("https://official-source.example/article", text: $sourceURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                } header: {
                    Text("Verified journalist response")
                } footer: {
                    Text("Use an official document or published reporting source. Users receive the answer only after you publish it.")
                }

                if let feedbackMessage {
                    Section {
                        Label(feedbackMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        save(publish: false)
                    } label: {
                        Label("Save Draft", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!isResponseValid || isSaving || isPublished)

                    Button {
                        save(publish: true)
                    } label: {
                        Label(
                            isPublished ? "Publish Verified Update" : "Publish Answer to Users",
                            systemImage: "paperplane.fill"
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(!isResponseValid || isSaving)

                    Button("Dismiss as Not a Reporting Gap", role: .destructive) {
                        isConfirmingDismissal = true
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(isSaving)
                }

                Section {
                    Text("Publishing resolves the linked questions and privately notifies their askers. Community names and contact information are never shown here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Review topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadDraft() }
            .confirmationDialog(
                "Dismiss this reporting lead?",
                isPresented: $isConfirmingDismissal,
                titleVisibility: .visible
            ) {
                Button("Dismiss Lead", role: .destructive, action: dismissLead)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It will leave the active journalist inbox, but its research audit record will be preserved.")
            }
        }
    }

    private var displayCategory: String {
        cluster.category.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var verifiedSourceURL: URL? {
        guard let url = URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private var isResponseValid: Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && verifiedSourceURL != nil
    }

    @MainActor
    private func loadDraft() async {
        isLoadingDraft = true
        defer { isLoadingDraft = false }
        do {
            if let draft = try await service.fetchResponse(for: cluster.id) {
                answer = draft.responseText
                sourceTitle = draft.sourceTitle
                sourceURL = draft.sourceURL.absoluteString
                if draft.responseStatus == "published" {
                    isPublished = true
                    feedbackMessage = "This answer has already been published."
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(publish: Bool) {
        guard let verifiedSourceURL else { return }
        isSaving = true
        feedbackMessage = nil
        errorMessage = nil

        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await service.saveResponse(
                    clusterID: cluster.id,
                    answer: answer.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceTitle: sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceURL: verifiedSourceURL,
                    publish: publish
                )
                feedbackMessage = publish
                    ? "Published and delivered to affected users."
                    : "Draft saved."
                onChanged()
                if publish {
                    try? await Task.sleep(for: .milliseconds(500))
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func dismissLead() {
        isSaving = true
        feedbackMessage = nil
        errorMessage = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await service.dismiss(
                    clusterID: cluster.id,
                    reason: "Dismissed as not a reporting gap after journalist review."
                )
                onChanged()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
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
