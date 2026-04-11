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

            let results = parseResults(from: html)

            if results.isEmpty {
                return .success("No results found for: \(query)")
            }

            let formatted = results.prefix(5).enumerated().map { index, result in
                "\(index + 1). \(result.title)\n   \(result.snippet)\n   URL: \(result.url)"
            }.joined(separator: "\n\n")

            return .success("Web search results for \"\(query)\":\n\n\(formatted)")
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

    private func parseResults(from html: String) -> [WebSearchResult] {
        var results: [WebSearchResult] = []

        let resultPattern = #"<a rel="nofollow" class="result__a" href="([^"]*)"[^>]*>(.+?)</a>"#
        let snippetPattern = #"<a class="result__snippet"[^>]*>(.+?)</a>"#

        guard let resultRegex = try? NSRegularExpression(pattern: resultPattern, options: .dotMatchesLineSeparators),
              let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: .dotMatchesLineSeparators) else {
            return results
        }

        let nsHTML = html as NSString
        let resultMatches = resultRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        let snippetMatches = snippetRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        for i in 0..<min(resultMatches.count, 5) {
            let match = resultMatches[i]

            guard match.numberOfRanges >= 3 else { continue }

            let rawURL = nsHTML.substring(with: match.range(at: 1))
            let rawTitle = nsHTML.substring(with: match.range(at: 2))

            let cleanTitle = stripHTML(rawTitle)
            let cleanURL = extractCleanURL(from: rawURL)

            var snippet = ""
            if i < snippetMatches.count, snippetMatches[i].numberOfRanges >= 2 {
                snippet = stripHTML(nsHTML.substring(with: snippetMatches[i].range(at: 1)))
            }

            guard !cleanTitle.isEmpty else { continue }

            results.append(WebSearchResult(title: cleanTitle, snippet: snippet, url: cleanURL))
        }

        return results
    }

    private func stripHTML(_ input: String) -> String {
        var result = input.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#x27;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractCleanURL(from duckDuckGoRedirect: String) -> String {
        if let components = URLComponents(string: duckDuckGoRedirect),
           let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return uddg
        }
        return duckDuckGoRedirect
    }
}
