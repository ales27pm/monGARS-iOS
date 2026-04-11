import Foundation

nonisolated struct WebSearchResult: Sendable {
    let title: String
    let snippet: String
    let url: String
}

nonisolated final class WebSearchTool: ToolExecutable, @unchecked Sendable {
    let schema = ToolSchema(
        name: "web_search",
        description: "Searches the web for information. This tool requires an active internet connection and must be enabled in settings. Returns titles, snippets, and URLs from search results.",
        parameters: [
            ToolParameter(name: "query", description: "The search query", type: .string, required: true),
            ToolParameter(name: "language", description: "Preferred result language (en or fr, defaults to en)", type: .string, required: false),
        ],
        requiresApproval: true,
        requiresNetwork: true
    )

    private let parser = WebSearchResultParser()

    func execute(arguments: [String: String]) async -> ToolCallResult {
        guard let query = arguments["query"], !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Missing or empty 'query' parameter")
        }

        let language = arguments["language"] ?? "en"
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let urlString = "https://html.duckduckgo.com/html/?q=\(encodedQuery)&kl=\(language)-ca"

        guard let url = URL(string: urlString) else {
            return .failure("Could not construct search URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("Invalid response from search provider")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                return .failure("Search provider returned status \(httpResponse.statusCode)")
            }

            guard let html = String(data: data, encoding: .utf8) else {
                return .failure("Could not decode search response")
            }

            let results = parser.parse(html: html)
            let formatted = parser.format(results: results, query: query)

            return .success(formatted)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return .failure("No internet connection available. Web search requires network access.")
            case .timedOut:
                return .failure("Search request timed out. The network may be slow or unavailable.")
            case .cannotFindHost, .cannotConnectToHost:
                return .failure("Could not reach search provider. Check your internet connection.")
            default:
                return .failure("Network error: \(error.localizedDescription)")
            }
        } catch {
            return .failure("Search failed: \(error.localizedDescription)")
        }
    }
}
