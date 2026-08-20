import Foundation

enum AppConfiguration {
    // Create a Supabase project, then replace only these two public client values.
    // Never place a Supabase secret key or service-role key in an iOS application.
    static let supabaseURL = "https://rajxtpjbwhcilvwyvrkz.supabase.co"
    static let supabasePublishableKey = "sb_publishable_LYt5UDCkuktF5D7chsiWIA_AQanjNQT"

    // Public FastAPI backend hosted on Render. The Free instance can take about
    // a minute to wake after a period without traffic.
    static let chatAPIBaseURL = URL(string: "https://mynewsbuddy-api.onrender.com")

    static var isSupabaseConfigured: Bool {
        guard
            let url = URL(string: supabaseURL),
            url.scheme == "https",
            !supabaseURL.contains("YOUR_PROJECT_REF"),
            !supabasePublishableKey.contains("REPLACE_WITH_YOUR_KEY"),
            supabasePublishableKey.hasPrefix("sb_publishable_")
        else {
            return false
        }

        return true
    }
}

struct AuthConfiguration {
    let projectURL: URL
    let publishableKey: String

    static func load() throws -> AuthConfiguration {
        guard AppConfiguration.isSupabaseConfigured,
              let projectURL = URL(string: AppConfiguration.supabaseURL) else {
            throw AuthenticationError.notConfigured
        }

        return AuthConfiguration(
            projectURL: projectURL,
            publishableKey: AppConfiguration.supabasePublishableKey
        )
    }
}
