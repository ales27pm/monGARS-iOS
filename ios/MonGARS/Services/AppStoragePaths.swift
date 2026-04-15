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

    static func preparePersistentDirectories() {
        let fileManager = FileManager.default
        let requiredDirectories = [appRootDirectory, modelsDirectory, dataDirectory]

        for directory in requiredDirectories {
            if !fileManager.fileExists(atPath: directory.path) {
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    logger.error("Failed to create storage directory \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
