import Foundation
import os

nonisolated protocol TokenizerProtocol: Sendable {
    func encode(_ text: String) -> [Int]
    func decode(_ tokens: [Int]) -> String
    var vocabSize: Int { get }
    var bosTokenId: Int { get }
    var eosTokenId: Int { get }
}

actor TokenizerService {
    private let logger = Logger(subsystem: "com.mongars.ai", category: "tokenizer")

    private var vocabulary: [String: Int] = [:]
    private var reverseVocabulary: [Int: String] = [:]
    private var merges: [(String, String)] = []
    private var addedTokens: [String: Int] = [:]
    private var addedTokensDecoder: [Int: String] = [:]
    private var isLoaded: Bool = false
    private var byteEncoder: [Int: String] = [:]
    private var byteDecoder: [String: Int] = [:]

    private(set) var vocabSize: Int = 0
    private(set) var bosTokenId: Int = 1
    private(set) var eosTokenId: Int = 2

    func load(from directory: URL) throws {
        let tokenizerJsonURL = directory.appendingPathComponent("tokenizer.json")
        let vocabURL = directory.appendingPathComponent("vocab.json")
        let mergesURL = directory.appendingPathComponent("merges.txt")
        let configURL = directory.appendingPathComponent("tokenizer_config.json")

        buildByteEncoder()

        if FileManager.default.fileExists(atPath: tokenizerJsonURL.path) {
            try loadHuggingFaceTokenizer(at: tokenizerJsonURL)
        } else if FileManager.default.fileExists(atPath: vocabURL.path) {
            try loadLegacyVocab(vocabURL: vocabURL, mergesURL: mergesURL)
        } else {
            throw TokenizerError.vocabFileNotFound
        }

        if FileManager.default.fileExists(atPath: configURL.path) {
            try loadConfig(at: configURL)
        }

        vocabSize = vocabulary.count + addedTokens.count
        isLoaded = true
        logger.info("Tokenizer loaded: vocab=\(self.vocabSize) merges=\(self.merges.count) added=\(self.addedTokens.count)")
    }

    func encode(_ text: String) -> [Int] {
        guard isLoaded else { return [] }

        var tokens: [Int] = [bosTokenId]

        var remaining = text
        while !remaining.isEmpty {
            var matched = false
            for (token, id) in addedTokens.sorted(by: { $0.key.count > $1.key.count }) {
                if remaining.hasPrefix(token) {
                    tokens.append(id)
                    remaining.removeFirst(token.count)
                    matched = true
                    break
                }
            }
            if matched { continue }

            let (word, rest) = extractNextWord(from: remaining)
            remaining = rest

            let byteEncoded = byteEncodeWord(word)
            let subTokens = bpeEncode(byteEncoded)
            for sub in subTokens {
                if let id = vocabulary[sub] {
                    tokens.append(id)
                } else if let id = addedTokens[sub] {
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
            if let piece = addedTokensDecoder[token] {
                pieces.append(piece)
            } else if let piece = reverseVocabulary[token] {
                pieces.append(piece)
            }
        }

        let raw = pieces.joined()
        return byteDecodeString(raw)
    }

    // MARK: - HuggingFace tokenizer.json Parsing

    private func loadHuggingFaceTokenizer(at url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TokenizerError.invalidFormat
        }

        if let model = json["model"] as? [String: Any] {
            if let vocab = model["vocab"] as? [String: Int] {
                vocabulary = vocab
                reverseVocabulary = Dictionary(uniqueKeysWithValues: vocab.map { ($0.value, $0.key) })
            }

            if let mergesList = model["merges"] as? [String] {
                merges = mergesList.compactMap { line in
                    let parts = line.split(separator: " ")
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
            }
        }

        if let addedList = json["added_tokens"] as? [[String: Any]] {
            for entry in addedList {
                guard let content = entry["content"] as? String,
                      let id = entry["id"] as? Int else { continue }
                addedTokens[content] = id
                addedTokensDecoder[id] = content

                if content == "<|begin_of_text|>" || content == "<s>" {
                    bosTokenId = id
                }
                if content == "<|end_of_text|>" || content == "</s>" || content == "<|eot_id|>" {
                    eosTokenId = id
                }
            }
        }
    }

    private func loadLegacyVocab(vocabURL: URL, mergesURL: URL) throws {
        let vocabData = try Data(contentsOf: vocabURL)
        vocabulary = try JSONDecoder().decode([String: Int].self, from: vocabData)
        reverseVocabulary = Dictionary(uniqueKeysWithValues: vocabulary.map { ($0.value, $0.key) })

        if FileManager.default.fileExists(atPath: mergesURL.path) {
            let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
            merges = mergesText
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("version") }
                .compactMap { line in
                    let parts = line.split(separator: " ")
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
        }
    }

    private func loadConfig(at url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let bosId = json["bos_token_id"] as? Int {
            bosTokenId = bosId
        }
        if let eosId = json["eos_token_id"] as? Int {
            eosTokenId = eosId
        }

        if let bosToken = json["bos_token"] as? String, let id = vocabulary[bosToken] ?? addedTokens[bosToken] {
            bosTokenId = id
        }
        if let eosToken = json["eos_token"] as? String, let id = vocabulary[eosToken] ?? addedTokens[eosToken] {
            eosTokenId = id
        }
    }

    // MARK: - BPE

    private func extractNextWord(from text: String) -> (String, String) {
        guard let first = text.first else { return ("", "") }

        if first.isWhitespace {
            var idx = text.startIndex
            while idx < text.endIndex && text[idx].isWhitespace {
                idx = text.index(after: idx)
            }
            if idx < text.endIndex {
                var wordEnd = idx
                while wordEnd < text.endIndex && !text[wordEnd].isWhitespace {
                    wordEnd = text.index(after: wordEnd)
                }
                let word = " " + String(text[idx..<wordEnd])
                let rest = String(text[wordEnd...])
                return (word, rest)
            }
            return (String(text[text.startIndex..<idx]), "")
        }

        var wordEnd = text.startIndex
        while wordEnd < text.endIndex && !text[wordEnd].isWhitespace {
            wordEnd = text.index(after: wordEnd)
        }
        return (String(text[text.startIndex..<wordEnd]), String(text[wordEnd...]))
    }

    private func bpeEncode(_ word: String) -> [String] {
        guard word.count > 1 else { return [word] }

        var symbols = word.map { String($0) }

        while symbols.count > 1 {
            var bestMerge: (String, String)?
            var bestRank = Int.max

            for i in 0..<(symbols.count - 1) {
                let pair = (symbols[i], symbols[i + 1])
                if let rank = mergeRank(pair), rank < bestRank {
                    bestRank = rank
                    bestMerge = pair
                }
            }

            guard let merge = bestMerge else { break }

            var newSymbols: [String] = []
            var i = 0
            while i < symbols.count {
                if i < symbols.count - 1 && symbols[i] == merge.0 && symbols[i + 1] == merge.1 {
                    newSymbols.append(merge.0 + merge.1)
                    i += 2
                } else {
                    newSymbols.append(symbols[i])
                    i += 1
                }
            }
            symbols = newSymbols
        }

        return symbols
    }

    private func mergeRank(_ pair: (String, String)) -> Int? {
        for (i, merge) in merges.enumerated() {
            if merge.0 == pair.0 && merge.1 == pair.1 {
                return i
            }
        }
        return nil
    }

    // MARK: - Byte-Level BPE

    private func buildByteEncoder() {
        var encoder: [Int: String] = [:]
        var n = 0

        for b in 33...126 {
            encoder[b] = String(UnicodeScalar(b)!)
            n += 1
        }
        for b in 161...172 {
            encoder[b] = String(UnicodeScalar(b)!)
            n += 1
        }
        for b in 174...255 {
            encoder[b] = String(UnicodeScalar(b)!)
            n += 1
        }

        var offset = 256
        for b in 0...255 {
            if encoder[b] == nil {
                encoder[b] = String(UnicodeScalar(offset)!)
                offset += 1
            }
        }

        byteEncoder = encoder
        byteDecoder = Dictionary(uniqueKeysWithValues: encoder.map { ($0.value, $0.key) })
    }

    private func byteEncodeWord(_ word: String) -> String {
        let utf8 = Array(word.utf8)
        return utf8.compactMap { byteEncoder[Int($0)] }.joined()
    }

    private func byteDecodeString(_ text: String) -> String {
        let bytes = text.unicodeScalars.compactMap { scalar -> UInt8? in
            if let b = byteDecoder[String(scalar)] {
                return UInt8(b)
            }
            return nil
        }
        return String(bytes: bytes, encoding: .utf8) ?? text
    }
}

nonisolated enum TokenizerError: Error, Sendable {
    case vocabFileNotFound
    case mergesFileNotFound
    case invalidFormat
}
