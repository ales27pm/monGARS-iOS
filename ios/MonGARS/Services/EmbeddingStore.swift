import Accelerate
import Foundation
import SQLite3
import os

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor EmbeddingStore {
    private var db: OpaquePointer?
    private let dbPath: URL
    private let logger = Logger(subsystem: "com.mongars.memory", category: "storage")
    private var storagePreparationError: Error?

    init() {
        do {
            try AppStoragePaths.preparePersistentDirectories()
            try migrateLegacyEmbeddingsIfNeeded()
        } catch {
            storagePreparationError = error
            logger.error("Failed to prepare embedding storage: \(error.localizedDescription, privacy: .public)")
        }
        self.dbPath = AppStoragePaths.embeddingsDatabaseURL
    }

    func open() throws {
        if let storagePreparationError {
            throw EmbeddingStoreError.storageSetupFailed(storagePreparationError.localizedDescription)
        }

        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw EmbeddingStoreError.openFailed(msg)
        }

        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")

        try execute("""
            CREATE TABLE IF NOT EXISTS chunks (
                id TEXT PRIMARY KEY,
                content TEXT NOT NULL,
                source TEXT NOT NULL,
                language TEXT,
                created_at REAL NOT NULL,
                vector BLOB NOT NULL,
                dimensions INTEGER NOT NULL
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_chunks_source ON chunks(source)")
        try execute("CREATE INDEX IF NOT EXISTS idx_chunks_language ON chunks(language)")
    }

    func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    func insertChunk(_ chunk: SemanticChunk) throws {
        guard let db else { throw EmbeddingStoreError.notOpen }

        let sql = """
            INSERT OR REPLACE INTO chunks (id, content, source, language, created_at, vector, dimensions)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EmbeddingStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (chunk.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (chunk.content as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (chunk.source as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let lang = chunk.language {
            sqlite3_bind_text(stmt, 4, (lang as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_double(stmt, 5, chunk.createdAt.timeIntervalSince1970)

        let vectorData = chunk.vector.withUnsafeBufferPointer { Data(buffer: $0) }
        vectorData.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 6, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int(stmt, 7, Int32(chunk.dimensions))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EmbeddingStoreError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func searchSimilar(queryVector: [Float], topK: Int = 5, source: String? = nil, language: String? = nil, minScore: Float = 0.3) throws -> [ScoredChunk] {
        let chunks = try allChunks(source: source, language: language)
        guard !chunks.isEmpty else { return [] }

        var scored: [ScoredChunk] = []
        scored.reserveCapacity(chunks.count)

        for chunk in chunks {
            guard chunk.vector.count == queryVector.count else { continue }
            let score = cosineSimilarity(queryVector, chunk.vector)
            if score >= minScore {
                scored.append(ScoredChunk(chunk: chunk, score: score))
            }
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(topK))
    }

    func allChunks(source: String? = nil, language: String? = nil) throws -> [SemanticChunk] {
        guard let db else { throw EmbeddingStoreError.notOpen }

        var sql = "SELECT id, content, source, language, created_at, vector, dimensions FROM chunks"
        var conditions: [String] = []
        if source != nil { conditions.append("source = ?") }
        if language != nil { conditions.append("language = ?") }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY created_at DESC"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EmbeddingStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var bindIdx: Int32 = 1
        if let source {
            sqlite3_bind_text(stmt, bindIdx, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
            bindIdx += 1
        }
        if let language {
            sqlite3_bind_text(stmt, bindIdx, (language as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }

        var chunks: [SemanticChunk] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let content = String(cString: sqlite3_column_text(stmt, 1))
            let sourceVal = String(cString: sqlite3_column_text(stmt, 2))
            let lang: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3))
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))

            let blobPtr = sqlite3_column_blob(stmt, 5)
            let blobSize = Int(sqlite3_column_bytes(stmt, 5))
            let dims = Int(sqlite3_column_int(stmt, 6))

            var vector: [Float] = []
            if let blobPtr, blobSize > 0 {
                let floatCount = blobSize / MemoryLayout<Float>.size
                vector = Array(UnsafeBufferPointer(
                    start: blobPtr.assumingMemoryBound(to: Float.self),
                    count: floatCount
                ))
            }

            chunks.append(SemanticChunk(
                id: id,
                content: content,
                source: sourceVal,
                language: lang,
                createdAt: createdAt,
                vector: vector,
                dimensions: dims
            ))
        }
        return chunks
    }

    func deleteChunks(source: String) throws {
        guard let db else { throw EmbeddingStoreError.notOpen }
        let sql = "DELETE FROM chunks WHERE source = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EmbeddingStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func deleteAll() throws {
        try execute("DELETE FROM chunks")
    }

    func chunkCount() throws -> Int {
        guard let db else { throw EmbeddingStoreError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM chunks", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))

        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw EmbeddingStoreError.notOpen }
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw EmbeddingStoreError.execFailed(msg)
        }
    }

    private func migrateLegacyEmbeddingsIfNeeded() throws {
        let legacyDBURL = URL.documentsDirectory.appending(path: "embeddings.sqlite3", directoryHint: .notDirectory)
        let newDBURL = AppStoragePaths.embeddingsDatabaseURL
        let helperFiles = ["-wal", "-shm"]

        guard FileManager.default.fileExists(atPath: legacyDBURL.path) else { return }
        if FileManager.default.fileExists(atPath: newDBURL.path) {
            logger.info("Skipping legacy embeddings migration because new database already exists")
            return
        }

        try FileManager.default.moveItem(at: legacyDBURL, to: newDBURL)

        for suffix in helperFiles {
            let legacyHelper = URL(fileURLWithPath: legacyDBURL.path + suffix)
            let newHelper = URL(fileURLWithPath: newDBURL.path + suffix)
            if FileManager.default.fileExists(atPath: legacyHelper.path), !FileManager.default.fileExists(atPath: newHelper.path) {
                try FileManager.default.moveItem(at: legacyHelper, to: newHelper)
            }
        }

        logger.info("Migrated legacy embeddings database to new app folder")
    }
}

nonisolated struct SemanticChunk: Sendable {
    let id: String
    let content: String
    let source: String
    let language: String?
    let createdAt: Date
    let vector: [Float]
    let dimensions: Int

    init(id: String = UUID().uuidString, content: String, source: String, language: String? = nil, createdAt: Date = Date(), vector: [Float], dimensions: Int) {
        self.id = id
        self.content = content
        self.source = source
        self.language = language
        self.createdAt = createdAt
        self.vector = vector
        self.dimensions = dimensions
    }
}

nonisolated struct ScoredChunk: Sendable {
    let chunk: SemanticChunk
    let score: Float
}

nonisolated enum EmbeddingStoreError: Error, Sendable {
    case storageSetupFailed(String)
    case openFailed(String)
    case notOpen
    case prepareFailed(String)
    case insertFailed(String)
    case execFailed(String)
}
