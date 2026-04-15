import Foundation
import os

enum AppStoragePaths {
    private static let storageMigrationQueue = DispatchQueue(label: "com.mongars.storage.migration")

    static let appFolderName = "MonGARS"

    static var appRootDirectory: URL {
        URL.documentsDirectory.appending(path: appFolderName, directoryHint: .isDirectory)
    }

    static var modelsDirectory: URL {
        appRootDirectory.appending(path: "models", directoryHint: .isDirectory)
    }

    static var legacyDataDirectory: URL {
        appRootDirectory.appending(path: "data", directoryHint: .isDirectory)
    }

    static var embeddingsDatabaseURL: URL {
        applicationSupportDirectory.appending(path: appFolderName, directoryHint: .isDirectory)
            .appending(path: "embeddings.sqlite3", directoryHint: .notDirectory)
    }

    static var applicationSupportDirectory: URL {
        let fileManager = FileManager.default
        let logger = Logger(subsystem: "com.mongars.storage", category: "paths")
        do {
            return try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            logger.error("Failed to resolve application support directory: \(error.localizedDescription, privacy: .public)")
            return URL.documentsDirectory
        }
    }

    static var embeddingsDirectory: URL {
        embeddingsDatabaseURL.deletingLastPathComponent()
    }

    static var legacyEmbeddingsDatabaseURL: URL {
        URL.documentsDirectory.appending(path: "embeddings.sqlite3", directoryHint: .notDirectory)
    }

    static var legacyEmbeddingsDatabaseInAppFolderURL: URL {
        legacyDataDirectory.appending(path: "embeddings.sqlite3", directoryHint: .notDirectory)
    }

    static var legacyModelsDirectory: URL {
        URL.documentsDirectory.appending(path: "models", directoryHint: .isDirectory)
    }

    /// Ensures that all required app storage directories exist and are directories.
    /// - Throws: `StoragePathError` when an expected directory is a file,
    ///           or any underlying `FileManager` creation error.
    static func preparePersistentDirectories() throws {
        let result: Result<Void, Error> = storageMigrationQueue.sync {
            let fileManager = FileManager.default
            let logger = Logger(subsystem: "com.mongars.storage", category: "paths")
            let requiredDirectories = [appRootDirectory, modelsDirectory, embeddingsDirectory]

            do {
                for directory in requiredDirectories {
                    var isDirectory: ObjCBool = false
                    let exists = fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                    if exists {
                        guard isDirectory.boolValue else {
                            let error = StoragePathError.pathExistsAsFile(directory)
                            logger.error("Storage path exists as file: \(directory.path, privacy: .public)")
                            throw error
                        }
                        continue
                    }

                    do {
                        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    } catch {
                        logger.error("Failed to create storage directory \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        throw error
                    }
                }

                try migrateLegacyStorageIfNeeded()
                applyEmbeddingsFilePermissionsBestEffort()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    private static func migrateLegacyStorageIfNeeded() throws {
        try migrateLegacyModelsIfNeeded()
        try migrateLegacyEmbeddingsIfNeeded()
    }

    private static func migrateLegacyModelsIfNeeded() throws {
        let fileManager = FileManager.default
        let logger = Logger(subsystem: "com.mongars.storage", category: "paths")
        var legacyIsDir: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyModelsDirectory.path, isDirectory: &legacyIsDir), legacyIsDir.boolValue else {
            return
        }

        var newIsDir: ObjCBool = false
        let destinationExists = fileManager.fileExists(atPath: modelsDirectory.path, isDirectory: &newIsDir)
        if !destinationExists {
            try fileManager.moveItem(at: legacyModelsDirectory, to: modelsDirectory)
            logger.info("Migrated legacy models directory")
            return
        }

        guard newIsDir.boolValue else {
            throw StoragePathError.pathExistsAsFile(modelsDirectory)
        }

        let legacyItems = try fileManager.contentsOfDirectory(at: legacyModelsDirectory, includingPropertiesForKeys: nil)
        for legacyItem in legacyItems {
            let destination = modelsDirectory.appendingPathComponent(legacyItem.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                continue
            }
            try fileManager.moveItem(at: legacyItem, to: destination)
        }

        let remainingItems = (try? fileManager.contentsOfDirectory(at: legacyModelsDirectory, includingPropertiesForKeys: nil)) ?? []
        if remainingItems.isEmpty {
            try? fileManager.removeItem(at: legacyModelsDirectory)
        }
    }

    private static func migrateLegacyEmbeddingsIfNeeded() throws {
        let fileManager = FileManager.default
        let logger = Logger(subsystem: "com.mongars.storage", category: "paths")
        if fileManager.fileExists(atPath: embeddingsDatabaseURL.path) {
            return
        }

        let candidateSources = [legacyEmbeddingsDatabaseInAppFolderURL, legacyEmbeddingsDatabaseURL]
        guard let source = candidateSources.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return
        }

        try fileManager.moveItem(at: source, to: embeddingsDatabaseURL)
        try migrateSQLiteSidecars(from: source, to: embeddingsDatabaseURL)
        logger.info("Migrated legacy embeddings database from \(source.path, privacy: .public)")
    }

    private static func migrateSQLiteSidecars(from sourceDB: URL, to destinationDB: URL) throws {
        let fileManager = FileManager.default
        let suffixes = ["-wal", "-shm"]
        for suffix in suffixes {
            let sourceSidecar = URL(fileURLWithPath: sourceDB.path + suffix)
            let destinationSidecar = URL(fileURLWithPath: destinationDB.path + suffix)
            if fileManager.fileExists(atPath: sourceSidecar.path),
               !fileManager.fileExists(atPath: destinationSidecar.path) {
                try fileManager.moveItem(at: sourceSidecar, to: destinationSidecar)
            }
        }
    }

    private static func applyEmbeddingsFilePermissionsBestEffort() {
        let fileManager = FileManager.default
        let logger = Logger(subsystem: "com.mongars.storage", category: "paths")
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: embeddingsDirectory.path)
            if fileManager.fileExists(atPath: embeddingsDatabaseURL.path) {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: embeddingsDatabaseURL.path)
            }
        } catch {
            logger.warning("Unable to apply embeddings file permissions: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum StoragePathError: LocalizedError {
    case pathExistsAsFile(URL)

    var errorDescription: String? {
        switch self {
        case .pathExistsAsFile(let url):
            return "Expected directory but found file at \(url.path)"
        }
    }
}
