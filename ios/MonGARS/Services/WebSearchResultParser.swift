import Foundation

nonisolated struct WebSearchResultParser: Sendable {

    func parse(html: String) -> [WebSearchResult] {
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

    func format(results: [WebSearchResult], query: String) -> String {
        if results.isEmpty {
            return "No results found for: \(query)"
        }

        let formatted = results.prefix(5).enumerated().map { index, result in
            "\(index + 1). \(result.title)\n   \(result.snippet)\n   URL: \(result.url)"
        }.joined(separator: "\n\n")

        return "Web search results for \"\(query)\":\n\n\(formatted)"
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
