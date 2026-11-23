import Foundation

#if !DEBUG
import PostHog
#endif

enum AnalyticsContentType: String {
    case match
    case team
    case player
    case article
}

enum AnalyticsErrorCategory: String {
    case offline
    case timeout
    case rateLimited = "rate_limited"
    case server
    case client
    case invalidResponse = "invalid_response"
    case invalidRequest = "invalid_request"
    case unknown

    init(_ error: Error) {
        guard let apiError = error as? VLRAPIError else {
            self = .unknown
            return
        }

        switch apiError {
        case .invalidURL:
            self = .invalidRequest
        case .invalidResponse:
            self = .invalidResponse
        case .httpStatus(429):
            self = .rateLimited
        case .httpStatus(let status) where (500...599).contains(status):
            self = .server
        case .httpStatus:
            self = .client
        case .transport(let code):
            switch code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                self = .offline
            case .timedOut:
                self = .timeout
            default:
                self = .unknown
            }
        case .requestFailed:
            self = .unknown
        }
    }
}

enum AnalyticsEvent {
    case primaryTabViewed(tab: String)
    case contentOpened(type: AnalyticsContentType, id: String, source: String, matchState: String? = nil)
    case searchPerformed(surface: String, resultCount: Int)
    case searchZeroResults(surface: String)
    case filterChanged(surface: String, filter: String, value: String)
    case articleShareStarted(id: String)
    case externalLinkOpened(destination: String, type: AnalyticsContentType, id: String, source: String)
    case retryTapped(surface: String)
    case loadFailed(surface: String, category: AnalyticsErrorCategory, retryable: Bool)
    case offlineCachePresented(surface: String, category: AnalyticsErrorCategory?)
    case preferenceChanged(preference: String, value: String)

    fileprivate var name: String {
        switch self {
        case .primaryTabViewed: "primary_tab_viewed"
        case .contentOpened: "content_opened"
        case .searchPerformed: "search_performed"
        case .searchZeroResults: "search_zero_results"
        case .filterChanged: "filter_changed"
        case .articleShareStarted: "article_share_started"
        case .externalLinkOpened: "external_link_opened"
        case .retryTapped: "retry_tapped"
        case .loadFailed: "load_failed"
        case .offlineCachePresented: "offline_cache_presented"
        case .preferenceChanged: "preference_changed"
        }
    }

    fileprivate var properties: [String: Any] {
        switch self {
        case .primaryTabViewed(let tab):
            ["surface": tab]
        case .contentOpened(let type, let id, let source, let matchState):
            compact([
                "content_type": type.rawValue,
                "content_id": id,
                "source": source,
                "match_state": matchState,
            ])
        case .searchPerformed(let surface, let resultCount):
            ["surface": surface, "result_count": resultCount]
        case .searchZeroResults(let surface):
            ["surface": surface]
        case .filterChanged(let surface, let filter, let value):
            ["surface": surface, "filter": filter, "value": value]
        case .articleShareStarted(let id):
            ["content_type": AnalyticsContentType.article.rawValue, "content_id": id]
        case .externalLinkOpened(let destination, let type, let id, let source):
            [
                "destination": destination,
                "content_type": type.rawValue,
                "content_id": id,
                "source": source,
            ]
        case .retryTapped(let surface):
            ["surface": surface]
        case .loadFailed(let surface, let category, let retryable):
            ["surface": surface, "error_category": category.rawValue, "retryable": retryable]
        case .offlineCachePresented(let surface, let category):
            compact([
                "surface": surface,
                "cache_state": "stale_offline",
                "error_category": category?.rawValue,
            ])
        case .preferenceChanged(let preference, let value):
            ["preference": preference, "value": value]
        }
    }

    private func compact(_ values: [String: Any?]) -> [String: Any] {
        values.reduce(into: [String: Any]()) { result, item in
            if let value = item.value {
                result[item.key] = value
            }
        }
    }
}

@MainActor
enum Analytics {
    #if !DEBUG
    private static let appVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "unknown"
    #endif

    static func configure() {
        #if !DEBUG
        let config = PostHogConfig(
            projectToken: "phc_yZc3oaeZxv5zaMmVup4YWQ6QqzQGVGZ5vWhxWc28Fkdx",
            host: "https://eu.i.posthog.com"
        )
        config.personProfiles = .never
        PostHogSDK.shared.setup(config)
        #endif
    }

    static func track(_ event: AnalyticsEvent) {
        #if DEBUG
        return
        #else
        var properties = event.properties
        properties["app_version"] = appVersion
        PostHogSDK.shared.capture(event.name, properties: properties)
        #endif
    }
}
