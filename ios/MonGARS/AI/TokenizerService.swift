import Foundation

nonisolated protocol TokenizerProtocol: Sendable {
    func encode(_ text: String) -> [Int]
    func decode(_ tokens: [Int]) -> String
    var vocabSize: Int { get }
    var bosTokenId: Int { get }
    var eosTokenId: Int { get }
}

actor TokenizerService {
    private var vocabulary: [String: Int] = [:]
    private var reverseVocabulary: [Int: String] = [:]
    private var merges: [(String, String)] = []
    private var isLoaded: Bool = false

    var vocabSize: Int { vocabulary.count }
    let bosTokenId: Int = 1
    let eosTokenId: Int = 2

    func load(from directory: URL) throws {
        let vocabURL = directory.appendingPathComponent("vocab.json")
        let mergesURL = directory.appendingPathComponent("merges.txt")

        guard FileManager.default.fileExists(atPath: vocabURL.path) else {
            throw TokenizerError.vocabFileNotFound
        }

        let vocabData = try Data(contentsOf: vocabURL)
        vocabulary = try JSONDecoder().decode([String: Int].self, from: vocabData)
        reverseVocabulary = Dictionary(uniqueKeysWithValues: vocabulary.map { ($0.value, $0.key) })

        if FileManager.default.fileExists(atPath: mergesURL.path) {
            let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
            merges = mergesText
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .compactMap { line in
                    let parts = line.split(separator: " ")
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
        }

        isLoaded = true
    }

    func encode(_ text: String) -> [Int] {
        guard isLoaded else { return [] }

        var tokens: [Int] = [bosTokenId]
        let words = tokenizeToWords(text)

        for word in words {
            let subTokens = bpeEncode(word)
            for sub in subTokens {
                if let id = vocabulary[sub] {
                    tokens.append(id)
                }
            }
        }

        return tokens
    }

    func decode(_ tokens: [Int]) -> String {
        guard isLoaded else { return "" }

        var pieces: [String] = []
        for token in tokens {
            guard token != bosTokenId && token != eosTokenId else { continue }
            if let piece = reverseVocabulary[token] {
                pieces.append(piece)
            }
        }

        let raw = pieces.joined()
        return decodeBPEOutput(raw)
    }

    private func tokenizeToWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""

        for char in text {
            if char.isWhitespace {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                words.append("\u{2581}")
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            words.append(current)
        }

        return words
    }

    private func bpeEncode(_ word: String) -> [String] {
        guard word.count > 1 else { return [word] }

        var symbols = word.map { String($0) }

        for (first, second) in merges {
            var i = 0
            while i < symbols.count - 1 {
                if symbols[i] == first && symbols[i + 1] == second {
                    symbols[i] = first + second
                    symbols.remove(at: i + 1)
                } else {
                    i += 1
                }
            }
        }

        return symbols
    }

    private func decodeBPEOutput(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

nonisolated enum TokenizerError: Error, Sendable {
    case vocabFileNotFound
    case mergesFileNotFound
    case invalidFormat
}
