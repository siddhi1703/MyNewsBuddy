import Foundation

struct ChatConversation: Identifiable, Decodable, Equatable {
    let id: UUID
    let title: String
    let createdAt: String
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var updatedDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: updatedAt) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: updatedAt)
    }

    var relativeUpdatedText: String? {
        updatedDate?.formatted(
            .relative(presentation: .named, unitsStyle: .wide)
        )
    }
}

struct StoredChatMessage: Identifiable, Decodable {
    let id: UUID
    let conversationID: UUID
    let role: String
    let content: String
    let answerState: String?
    let sourceTitle: String?
    let sourceURL: String?
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case role
        case content
        case answerState = "answer_state"
        case sourceTitle = "source_title"
        case sourceURL = "source_url"
        case createdAt = "created_at"
    }
}

enum ChatHistoryError: LocalizedError {
    case signedOut
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut:
            "Sign in again to use chat history."
        case .invalidResponse:
            "Chat history returned an unexpected response."
        case .server(let message):
            message
        }
    }
}

actor ChatHistoryService {
    private let authentication = SupabaseAuthService()

    func conversations() async throws -> [ChatConversation] {
        let data = try await request(
            table: "chat_conversations",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: "id,title,created_at,updated_at"),
                URLQueryItem(name: "order", value: "updated_at.desc")
            ]
        )
        return try decode([ChatConversation].self, from: data)
    }

    func messages(conversationID: UUID) async throws -> [StoredChatMessage] {
        let data = try await request(
            table: "chat_messages",
            method: "GET",
            queryItems: [
                URLQueryItem(
                    name: "select",
                    value: "id,conversation_id,role,content,answer_state,source_title,source_url,created_at"
                ),
                URLQueryItem(
                    name: "conversation_id",
                    value: "eq.\(conversationID.uuidString.lowercased())"
                ),
                URLQueryItem(name: "order", value: "created_at.asc")
            ]
        )
        return try decode([StoredChatMessage].self, from: data)
    }

    func saveUserMessage(
        conversationID: UUID?,
        question: String
    ) async throws -> UUID {
        let id: UUID
        if let conversationID {
            id = conversationID
        } else {
            id = try await createConversation(title: Self.title(from: question))
        }

        try await saveMessage(
            conversationID: id,
            role: "user",
            content: question,
            answerState: nil,
            sourceTitle: nil,
            sourceURL: nil
        )
        return id
    }

    func saveAssistantMessage(
        conversationID: UUID,
        content: String,
        answerState: String?,
        sourceTitle: String?,
        sourceURL: URL?
    ) async throws {
        try await saveMessage(
            conversationID: conversationID,
            role: "assistant",
            content: content,
            answerState: answerState,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL?.absoluteString
        )
    }

    func deleteConversation(_ id: UUID) async throws {
        _ = try await request(
            table: "chat_conversations",
            method: "DELETE",
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")
            ]
        )
    }

    private func createConversation(title: String) async throws -> UUID {
        let body = ConversationInsert(title: title)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try await request(
            table: "chat_conversations",
            method: "POST",
            body: try encoder.encode(body),
            preferRepresentation: true
        )
        guard let conversation = try decode([SavedConversation].self, from: data).first else {
            throw ChatHistoryError.invalidResponse
        }
        return conversation.id
    }

    private func saveMessage(
        conversationID: UUID,
        role: String,
        content: String,
        answerState: String?,
        sourceTitle: String?,
        sourceURL: String?
    ) async throws {
        let body = MessageInsert(
            conversationID: conversationID,
            role: role,
            content: content,
            answerState: answerState,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        _ = try await request(
            table: "chat_messages",
            method: "POST",
            body: try encoder.encode(body)
        )
    }

    private func request(
        table: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        preferRepresentation: Bool = false
    ) async throws -> Data {
        let configuration: AuthConfiguration
        do {
            configuration = try AuthConfiguration.load()
        } catch {
            throw ChatHistoryError.server(error.localizedDescription)
        }

        guard let accessToken = await authentication.currentAccessToken() else {
            throw ChatHistoryError.signedOut
        }

        let endpoint = configuration.projectURL.appending(path: "rest/v1/\(table)")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ChatHistoryError.invalidResponse
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw ChatHistoryError.invalidResponse
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
            throw ChatHistoryError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(ChatHistoryAPIError.self, from: data)
            throw ChatHistoryError.server(
                apiError?.bestMessage
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
        return data
    }

    private func decode<Response: Decodable>(
        _ type: Response.Type,
        from data: Data
    ) throws -> Response {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ChatHistoryError.invalidResponse
        }
    }

    private static func title(from question: String) -> String {
        let singleLine = question
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > 56 else { return singleLine }
        return String(singleLine.prefix(55)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

private struct ConversationInsert: Encodable {
    let title: String
}

private struct SavedConversation: Decodable {
    let id: UUID
}

private struct MessageInsert: Encodable {
    let conversationID: UUID
    let role: String
    let content: String
    let answerState: String?
    let sourceTitle: String?
    let sourceURL: String?
}

private struct ChatHistoryAPIError: Decodable {
    let message: String?
    let details: String?
    let hint: String?

    var bestMessage: String {
        message ?? details ?? hint ?? "Chat history could not be loaded."
    }
}
