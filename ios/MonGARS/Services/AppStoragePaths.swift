import Foundation
import os

enum AppStoragePaths {
    private static let logger = Logger(subsystem: "com.mongars.storage", category: "paths")

    static let appFolderName = "MonGARS"

    static var appRootDirectory: URL {
        URL.documentsDirectory.appending(path: appFolderName, directoryHint: .isDirectory)
    }

    static var modelsDirectory: URL {
        appRootDirectory.appending(path: "models", directoryHint: .isDirectory)
    }

    static var dataDirectory: URL {
        appRootDirectory.appending(path: "data", directoryHint: .isDirectory)
    }

    static var embeddingsDatabaseURL: URL {
        dataDirectory.appending(path: "embeddings.sqlite3", directoryHint: .notDirectory)
    }

    /// Ensures that all required app storage directories exist and are directories.
    /// - Throws: `StoragePathError` when an expected directory is a file,
    ///           or any underlying `FileManager` creation error.
    static func preparePersistentDirectories() throws {
        let fileManager = FileManager.default
        let requiredDirectories = [appRootDirectory, modelsDirectory, dataDirectory]

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
