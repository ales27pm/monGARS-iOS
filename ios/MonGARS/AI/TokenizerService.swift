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
    private static let readinessProbeText = "Tokenizer readiness probe 123."
    private static let knownBOSTokenNames = ["<|begin_of_text|>", "<s>", "<|im_start|>"]
    private static let knownEOSTokenNames = ["<|eot_id|>", "<|end_of_text|>", "</s>", "<|im_end|>", "<|endoftext|>"]
    private static let appKnownSpecialTokenNames = [
        "<|begin_of_text|>",
        "<|end_of_text|>",
        "<|eot_id|>",
        "<|start_header_id|>",
        "<|end_header_id|>",
        "<|im_start|>",
        "<|im_end|>",
        "<|endoftext|>",
        "<s>",
        "</s>"
    ]

    private var vocabulary: [String: Int] = [:]
    private var reverseVocabulary: [Int: String] = [:]
    private var merges: [(String, String)] = []
    private var addedTokens: [String: Int] = [:]
    private var addedTokensDecoder: [Int: String] = [:]
    private var resolvedSpecialTokenIDs: [String: Int] = [:]
    private var isLoaded: Bool = false
    private var byteEncoder: [Int: String] = [:]
    private var byteDecoder: [String: Int] = [:]

    private(set) var vocabSize: Int = 0
    private(set) var bosTokenId: Int = 1
    private(set) var eosTokenId: Int = 2

    func load(from directory: URL) throws {
        resetState()

        let tokenizerJsonURL = directory.appendingPathComponent("tokenizer.json")
        let vocabURL = directory.appendingPathComponent("vocab.json")
        let mergesURL = directory.appendingPathComponent("merges.txt")
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        let specialTokensMapURL = directory.appendingPathComponent("special_tokens_map.json")
        var config = TokenizerConfig()
        var specialTokensMap: [String: [SpecialTokenReference]] = [:]

        buildByteEncoder()

        if FileManager.default.fileExists(atPath: tokenizerJsonURL.path) {
            try loadHuggingFaceTokenizer(at: tokenizerJsonURL)
        } else if FileManager.default.fileExists(atPath: vocabURL.path) {
            try loadLegacyVocab(vocabURL: vocabURL, mergesURL: mergesURL)
        } else {
            throw TokenizerError.vocabFileNotFound
        }

        if FileManager.default.fileExists(atPath: configURL.path) {
            config = try loadConfig(at: configURL)
        }
        if FileManager.default.fileExists(atPath: specialTokensMapURL.path) {
            specialTokensMap = try loadSpecialTokensMap(at: specialTokensMapURL)
        }

        try resolveSpecialTokenIDs(config: config, specialTokensMap: specialTokensMap)

        vocabSize = vocabulary.count + addedTokens.count
        let probeTokenCount = try validateSemanticReadiness()
        isLoaded = true
        logReadinessSummary(probeTokenCount: probeTokenCount)
    }

    func encode(_ text: String) -> [Int] {
        guard isLoaded else { return [] }
        return encodeLoaded(text)
    }

    func decode(_ tokens: [Int]) -> String {
        guard isLoaded else { return "" }
        return decodeLoaded(tokens)
    }

    private func encodeLoaded(_ text: String) -> [Int] {
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

    private func decodeLoaded(_ tokens: [Int]) -> String {
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
        let parsed: HuggingFaceTokenizerFile
        do {
            parsed = try JSONDecoder().decode(HuggingFaceTokenizerFile.self, from: data)
        } catch {
            throw TokenizerError.invalidFormat
        }

        if let vocab = parsed.model?.vocab {
            vocabulary = vocab
            reverseVocabulary = Dictionary(uniqueKeysWithValues: vocab.map { ($0.value, $0.key) })
        }

        if let mergeSource = parsed.model?.merges {
            merges = mergeSource.parsedPairs
        }

        if let addedList = parsed.addedTokens {
            for entry in addedList {
                addedTokens[entry.content] = entry.id
                addedTokensDecoder[entry.id] = entry.content
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

    private func loadConfig(at url: URL) throws -> TokenizerConfig {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(TokenizerConfig.self, from: data)
        } catch {
            logger.warning("Tokenizer config parse failed; continuing with inferred specials")
            return TokenizerConfig()
        }
    }

    private func loadSpecialTokensMap(at url: URL) throws -> [String: [SpecialTokenReference]] {
        let data = try Data(contentsOf: url)
        do {
            let decoded = try JSONDecoder().decode([String: SpecialTokenReferenceList].self, from: data)
            return decoded.mapValues(\.references)
        } catch {
            logger.warning("special_tokens_map parse failed; continuing with inferred specials")
            return [:]
        }
    }

    private func resolveSpecialTokenIDs(config: TokenizerConfig, specialTokensMap: [String: [SpecialTokenReference]]) throws {
        var resolved: [String: Int] = [:]

        let bosCandidates = specialTokenCandidates(
            key: "bos_token",
            config: config,
            specialTokensMap: specialTokensMap,
            aliases: Self.knownBOSTokenNames
        )
        guard let resolvedBOS = resolveFirstValidTokenID(from: bosCandidates) else {
            throw TokenizerError.semanticValidationFailed(
                reason: "Missing usable BOS token ID from tokenizer config/added tokens"
            )
        }
        bosTokenId = resolvedBOS
        resolved["bos_token"] = resolvedBOS

        let eosCandidates = specialTokenCandidates(
            key: "eos_token",
            config: config,
            specialTokensMap: specialTokensMap,
            aliases: Self.knownEOSTokenNames
        )
        guard let resolvedEOS = resolveFirstValidTokenID(from: eosCandidates) else {
            throw TokenizerError.semanticValidationFailed(
                reason: "Missing usable EOS token ID from tokenizer config/added tokens"
            )
        }
        eosTokenId = resolvedEOS
        resolved["eos_token"] = resolvedEOS

        for key in ["pad_token", "unk_token", "sep_token", "cls_token", "mask_token"] {
            let candidates = specialTokenCandidates(key: key, config: config, specialTokensMap: specialTokensMap, aliases: [])
            guard !candidates.isEmpty else { continue }
            if let resolvedID = resolveFirstValidTokenID(from: candidates) {
                resolved[key] = resolvedID
            }
        }

        let additionalSpecialCandidates = (config.additionalSpecialTokens ?? []) + (specialTokensMap["additional_special_tokens"] ?? [])
        for reference in additionalSpecialCandidates {
            guard let tokenName = reference.content, let resolvedID = resolveTokenID(from: reference) else { continue }
            resolved[tokenName] = resolvedID
        }

        for tokenName in Self.appKnownSpecialTokenNames {
            if let resolvedID = idForToken(named: tokenName) {
                resolved[tokenName] = resolvedID
            }
        }

        resolvedSpecialTokenIDs = resolved
    }

    private func specialTokenCandidates(
        key: String,
        config: TokenizerConfig,
        specialTokensMap: [String: [SpecialTokenReference]],
        aliases: [String]
    ) -> [SpecialTokenReference] {
        var candidates: [SpecialTokenReference] = []
        if let configID = config.tokenID(for: key) {
            candidates.append(SpecialTokenReference(id: configID, content: nil))
        }
        if let configReference = config.tokenReference(for: key) {
            candidates.append(configReference)
        }
        if let mapReferences = specialTokensMap[key] {
            candidates.append(contentsOf: mapReferences)
        }
        candidates.append(contentsOf: aliases.map { SpecialTokenReference(id: nil, content: $0) })
        return candidates
    }

    private func resolveFirstValidTokenID(from references: [SpecialTokenReference]) -> Int? {
        for reference in references {
            if let id = resolveTokenID(from: reference) {
                return id
            }
        }
        return nil
    }

    private func resolveTokenID(from reference: SpecialTokenReference) -> Int? {
        if let id = reference.id, tokenExists(id: id) {
            return id
        }
        if let tokenName = reference.content, let id = idForToken(named: tokenName) {
            return id
        }
        return nil
    }

    private func idForToken(named tokenName: String) -> Int? {
        if let id = addedTokens[tokenName] { return id }
        return vocabulary[tokenName]
    }

    private func tokenExists(id: Int) -> Bool {
        reverseVocabulary[id] != nil || addedTokensDecoder[id] != nil
    }

    private func validateSemanticReadiness() throws -> Int {
        guard !vocabulary.isEmpty || !addedTokens.isEmpty else {
            throw TokenizerError.semanticValidationFailed(reason: "Tokenizer vocabulary is empty")
        }
        guard tokenExists(id: bosTokenId) else {
            throw TokenizerError.semanticValidationFailed(reason: "BOS token ID \(bosTokenId) is not present in tokenizer data")
        }
        guard tokenExists(id: eosTokenId) else {
            throw TokenizerError.semanticValidationFailed(reason: "EOS token ID \(eosTokenId) is not present in tokenizer data")
        }

        let probeTokens = encodeLoaded(Self.readinessProbeText)
        guard probeTokens.count > 1 else {
            throw TokenizerError.semanticValidationFailed(reason: "Readiness probe produced no decodable text tokens")
        }

        let decodedProbe = decodeLoaded(probeTokens)
        guard decodedProbe == Self.readinessProbeText else {
            throw TokenizerError.semanticValidationFailed(
                reason: "Readiness probe round-trip mismatch (decoded '\(decodedProbe)' from '\(Self.readinessProbeText)')"
            )
        }

        return probeTokens.count
    }

    private func logReadinessSummary(probeTokenCount: Int) {
        let resolvedAppSpecialCount = Self.appKnownSpecialTokenNames.reduce(into: 0) { count, tokenName in
            if resolvedSpecialTokenIDs[tokenName] != nil {
                count += 1
            }
        }
        logger.info(
            "Tokenizer ready: vocab=\(self.vocabSize) merges=\(self.merges.count) added=\(self.addedTokens.count) bos=\(self.bosTokenId) eos=\(self.eosTokenId) appSpecials=\(resolvedAppSpecialCount)/\(Self.appKnownSpecialTokenNames.count) probeTokens=\(probeTokenCount)"
        )
    }

    private func resetState() {
        vocabulary.removeAll(keepingCapacity: true)
        reverseVocabulary.removeAll(keepingCapacity: true)
        merges.removeAll(keepingCapacity: true)
        addedTokens.removeAll(keepingCapacity: true)
        addedTokensDecoder.removeAll(keepingCapacity: true)
        resolvedSpecialTokenIDs.removeAll(keepingCapacity: true)
        isLoaded = false
        vocabSize = 0
        bosTokenId = 1
        eosTokenId = 2
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

        for b in 33...126 {
            encoder[b] = String(UnicodeScalar(b)!)
        }
        for b in 161...172 {
            encoder[b] = String(UnicodeScalar(b)!)
        }
        for b in 174...255 {
            encoder[b] = String(UnicodeScalar(b)!)
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

    private struct HuggingFaceTokenizerFile: Decodable {
        struct Model: Decodable {
            let vocab: [String: Int]?
            let merges: BPEMergeSource?
        }

        struct AddedToken: Decodable {
            let id: Int
            let content: String
        }

        let model: Model?
        let addedTokens: [AddedToken]?

        enum CodingKeys: String, CodingKey {
            case model
            case addedTokens = "added_tokens"
        }
    }

    private enum BPEMergeSource: Decodable {
        case lines([String])
        case pairs([[String]])

        var parsedPairs: [(String, String)] {
            switch self {
            case .lines(let lines):
                return lines.compactMap { line in
                    let parts = line.split(whereSeparator: \.isWhitespace)
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
            case .pairs(let pairs):
                return pairs.compactMap { pair in
                    guard pair.count == 2 else { return nil }
                    return (pair[0], pair[1])
                }
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let lines = try? container.decode([String].self) {
                self = .lines(lines)
                return
            }
            if let pairs = try? container.decode([[String]].self) {
                self = .pairs(pairs)
                return
            }
            throw DecodingError.typeMismatch(
                BPEMergeSource.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported merges format")
            )
        }
    }

    private struct TokenizerConfig: Decodable {
        var bosTokenID: Int?
        var eosTokenID: Int?
        var padTokenID: Int?
        var unkTokenID: Int?
        var sepTokenID: Int?
        var clsTokenID: Int?
        var maskTokenID: Int?

        var bosToken: SpecialTokenReference?
        var eosToken: SpecialTokenReference?
        var padToken: SpecialTokenReference?
        var unkToken: SpecialTokenReference?
        var sepToken: SpecialTokenReference?
        var clsToken: SpecialTokenReference?
        var maskToken: SpecialTokenReference?
        var additionalSpecialTokens: [SpecialTokenReference]?

        init() {}

        enum CodingKeys: String, CodingKey {
            case bosTokenID = "bos_token_id"
            case eosTokenID = "eos_token_id"
            case padTokenID = "pad_token_id"
            case unkTokenID = "unk_token_id"
            case sepTokenID = "sep_token_id"
            case clsTokenID = "cls_token_id"
            case maskTokenID = "mask_token_id"

            case bosToken = "bos_token"
            case eosToken = "eos_token"
            case padToken = "pad_token"
            case unkToken = "unk_token"
            case sepToken = "sep_token"
            case clsToken = "cls_token"
            case maskToken = "mask_token"
            case additionalSpecialTokens = "additional_special_tokens"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            bosTokenID = try? container.decode(Int.self, forKey: .bosTokenID)
            eosTokenID = try? container.decode(Int.self, forKey: .eosTokenID)
            padTokenID = try? container.decode(Int.self, forKey: .padTokenID)
            unkTokenID = try? container.decode(Int.self, forKey: .unkTokenID)
            sepTokenID = try? container.decode(Int.self, forKey: .sepTokenID)
            clsTokenID = try? container.decode(Int.self, forKey: .clsTokenID)
            maskTokenID = try? container.decode(Int.self, forKey: .maskTokenID)

            bosToken = try? container.decode(SpecialTokenReference.self, forKey: .bosToken)
            eosToken = try? container.decode(SpecialTokenReference.self, forKey: .eosToken)
            padToken = try? container.decode(SpecialTokenReference.self, forKey: .padToken)
            unkToken = try? container.decode(SpecialTokenReference.self, forKey: .unkToken)
            sepToken = try? container.decode(SpecialTokenReference.self, forKey: .sepToken)
            clsToken = try? container.decode(SpecialTokenReference.self, forKey: .clsToken)
            maskToken = try? container.decode(SpecialTokenReference.self, forKey: .maskToken)
            additionalSpecialTokens = try? container.decode([SpecialTokenReference].self, forKey: .additionalSpecialTokens)
        }

        func tokenID(for key: String) -> Int? {
            switch key {
            case "bos_token":
                bosTokenID
            case "eos_token":
                eosTokenID
            case "pad_token":
                padTokenID
            case "unk_token":
                unkTokenID
            case "sep_token":
                sepTokenID
            case "cls_token":
                clsTokenID
            case "mask_token":
                maskTokenID
            default:
                nil
            }
        }

        func tokenReference(for key: String) -> SpecialTokenReference? {
            switch key {
            case "bos_token":
                bosToken
            case "eos_token":
                eosToken
            case "pad_token":
                padToken
            case "unk_token":
                unkToken
            case "sep_token":
                sepToken
            case "cls_token":
                clsToken
            case "mask_token":
                maskToken
            default:
                nil
            }
        }
    }

    private struct SpecialTokenReference: Decodable, Sendable {
        let id: Int?
        let content: String?

        init(id: Int?, content: String?) {
            self.id = id
            self.content = content
        }

        private struct TokenObject: Decodable {
            let id: Int?
            let content: String?
            let token: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let id = try? container.decode(Int.self) {
                self.id = id
                self.content = nil
                return
            }
            if let content = try? container.decode(String.self) {
                self.id = nil
                self.content = content
                return
            }
            if let object = try? container.decode(TokenObject.self) {
                self.id = object.id
                self.content = object.content ?? object.token
                return
            }
            throw DecodingError.typeMismatch(
                SpecialTokenReference.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported special token value")
            )
        }
    }

    private enum SpecialTokenReferenceList: Decodable {
        case single(SpecialTokenReference)
        case multiple([SpecialTokenReference])

        var references: [SpecialTokenReference] {
            switch self {
            case .single(let value):
                [value]
            case .multiple(let values):
                values
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(SpecialTokenReference.self) {
                self = .single(single)
                return
            }
            if let list = try? container.decode([SpecialTokenReference].self) {
                self = .multiple(list)
                return
            }
            throw DecodingError.typeMismatch(
                SpecialTokenReferenceList.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported special token list")
            )
        }
    }
}

nonisolated enum TokenizerError: Error, Sendable {
    case vocabFileNotFound
    case mergesFileNotFound
    case invalidFormat
    case semanticValidationFailed(reason: String)
}

extension TokenizerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .vocabFileNotFound:
            "Tokenizer vocabulary files not found"
        case .mergesFileNotFound:
            "Tokenizer merges file not found"
        case .invalidFormat:
            "Tokenizer format is invalid"
        case .semanticValidationFailed(let reason):
            "Tokenizer validation failed: \(reason)"
        }
    }
}
