import Foundation

/// TMDB-backed live search suggestion service matching CloudStream Android's SearchSuggestionApi.kt.
/// Uses TMDB multi-search endpoint to provide instant title recommendations as the user types.
@MainActor
final class SearchSuggestionService {
    static let shared = SearchSuggestionService()

    /// Read from the built app's Info.plist (injected via the TMDB_API_KEY
    /// build setting) — not hardcoded in source.
    private static let apiKey = Bundle.main.object(forInfoDictionaryKey: "TMDbApiKey") as? String ?? ""

    private var activeTask: Task<[SearchSuggestion], Never>?

    struct SearchSuggestion: Identifiable, Hashable {
        let id: String
        let title: String
        let mediaType: String?
        let year: String?
    }

    private init() {}

    /// Query items keep the search text one exact value, whatever it contains.
    nonisolated static func requestURL(query: String, apiKey: String) -> URL? {
        guard !apiKey.isEmpty, var components = URLComponents(string: "https://api.themoviedb.org/3/search/multi") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "page", value: "1"),
        ]
        // URLComponents leaves "+" literal, which servers decode as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacing("+", with: "%2B")
        return components.url
    }

    func fetchSuggestions(query: String) async -> [SearchSuggestion] {
        activeTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let task = Task<[SearchSuggestion], Never> {
            try? await Task.sleep(for: .milliseconds(200)) // 200ms debounce
            guard !Task.isCancelled else { return [] }

            guard let url = Self.requestURL(query: trimmed, apiKey: Self.apiKey) else { return [] }

            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200
            else { return [] }

            guard !Task.isCancelled else { return [] }

            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let results = json?["results"] as? [[String: Any]] ?? []

                var suggestions: [SearchSuggestion] = []
                var seenTitles = Set<String>()

                for item in results {
                    let mediaType = item["media_type"] as? String ?? ""
                    if mediaType == "person" { continue }

                    let title = (item["title"] as? String)
                        ?? (item["name"] as? String)
                        ?? (item["original_title"] as? String)
                        ?? (item["original_name"] as? String)

                    guard let title, !title.isEmpty else { continue }
                    let key = title.lowercased()
                    if seenTitles.contains(key) { continue }
                    seenTitles.insert(key)

                    let date = (item["release_date"] as? String) ?? (item["first_air_date"] as? String)
                    let year: String? = date.map { String($0.prefix(4)) }
                    let itemId = "\(item["id"] ?? UUID().uuidString)"

                    suggestions.append(
                        SearchSuggestion(
                            id: itemId,
                            title: title,
                            mediaType: mediaType.isEmpty ? nil : mediaType.capitalized,
                            year: year
                        )
                    )

                    if suggestions.count >= 6 {
                        break
                    }
                }
                return suggestions
            } catch {
                return []
            }
        }

        activeTask = task
        return await task.value
    }
}
