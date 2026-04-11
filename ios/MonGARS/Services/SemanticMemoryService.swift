import Foundation
import os

actor SemanticMemoryService {
    private let embeddingStore: EmbeddingStore
    private let embeddingEngine: EmbeddingEngine
    private let logger = Logger(subsystem: "com.mongars.memory", category: "semantic")

    private let maxChunkLength = 500
    private let overlapLength = 50

    init(embeddingStore: EmbeddingStore, embeddingEngine: EmbeddingEngine) {
        self.embeddingStore = embeddingStore
        self.embeddingEngine = embeddingEngine
    }

    var isReady: Bool {
        get async { await embeddingEngine.isReady }
    }

    func ingestMessage(content: String, source: String, language: String?) async {
        guard await embeddingEngine.isReady else {
            logger.warning("Embedding engine not ready — skipping ingestion")
            return
        }

        let chunks = splitIntoChunks(text: content)
        for chunk in chunks {
            do {
                let result = try await embeddingEngine.embed(text: chunk)
                let semanticChunk = SemanticChunk(
                    content: chunk,
                    source: source,
                    language: language,
                    vector: result.vector,
                    dimensions: result.dimensions
                )
                try await embeddingStore.insertChunk(semanticChunk)
            } catch {
                logger.error("Failed to ingest chunk: \(error.localizedDescription)")
            }
        }
    }

    func ingestConversationTurn(userMessage: String, assistantResponse: String, conversationId: String, language: String?) async {
        let combined = "User: \(userMessage)\nAssistant: \(assistantResponse)"
        await ingestMessage(content: combined, source: "conversation:\(conversationId)", language: language)
    }

    func retrieveContext(for query: String, topK: Int = 3, language: String? = nil) async -> [RetrievedContext] {
        guard await embeddingEngine.isReady else {
            logger.warning("Embedding engine not ready — no context retrieved")
            return []
        }

        do {
            let queryResult = try await embeddingEngine.embed(text: query)
            let scored = try await embeddingStore.searchSimilar(
                queryVector: queryResult.vector,
                topK: topK,
                language: language,
                minScore: 0.25
            )

            return scored.map { sc in
                RetrievedContext(
                    content: sc.chunk.content,
                    source: sc.chunk.source,
                    score: sc.score,
                    language: sc.chunk.language
                )
            }
        } catch {
            logger.error("Retrieval failed: \(error.localizedDescription)")
            return []
        }
    }

    func buildContextBlock(for query: String, language: String? = nil) async -> String? {
        let contexts = await retrieveContext(for: query, topK: 3, language: language)
        guard !contexts.isEmpty else { return nil }

        var block = "Relevant context from memory:\n"
        for (i, ctx) in contexts.enumerated() {
            block += "[\(i + 1)] (relevance: \(String(format: "%.0f%%", ctx.score * 100)))\n\(ctx.content)\n\n"
        }
        return block
    }

    func chunkCount() async -> Int {
        (try? await embeddingStore.chunkCount()) ?? 0
    }

    func clearMemory(source: String? = nil) async {
        do {
            if let source {
                try await embeddingStore.deleteChunks(source: source)
            } else {
                try await embeddingStore.deleteAll()
            }
        } catch {
            logger.error("Failed to clear memory: \(error.localizedDescription)")
        }
    }

    private func splitIntoChunks(text: String) -> [String] {
        guard text.count > maxChunkLength else { return [text] }

        var chunks: [String] = []
        let words = text.split(separator: " ")
        var current: [Substring] = []
        var currentLength = 0

        for word in words {
            if currentLength + word.count + 1 > maxChunkLength && !current.isEmpty {
                chunks.append(current.joined(separator: " "))

                let overlapWords = current.suffix(overlapLength / 10)
                current = Array(overlapWords)
                currentLength = current.reduce(0) { $0 + $1.count + 1 }
            }
            current.append(word)
            currentLength += word.count + 1
        }

        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
        }

        return chunks
    }
}

nonisolated struct RetrievedContext: Sendable {
    let content: String
    let source: String
    let score: Float
    let language: String?
}
