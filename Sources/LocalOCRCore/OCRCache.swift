import CryptoKit
import Foundation
import ImageIO

public struct OCRCacheKey: Sendable, Codable, Hashable {
    public let sourceSHA256: String
    public let page: Int
    public let settings: RecognitionSettings
    public let compatibilityVersion: String

    public init(
        sourceSHA256: String,
        page: Int,
        settings: RecognitionSettings,
        compatibilityVersion: String
    ) {
        self.sourceSHA256 = sourceSHA256
        self.page = page
        self.settings = settings
        self.compatibilityVersion = compatibilityVersion
    }
}

public actor OCRCache {
    private let rootURL: URL
    private let compatibilityVersion: String
    private let fileManager: FileManager

    public init(rootURL: URL, compatibilityVersion: String) {
        self.rootURL = rootURL
        self.compatibilityVersion = compatibilityVersion
        self.fileManager = .default
    }

    public func value(for key: OCRCacheKey) throws -> RecognitionCandidate? {
        let fileURL = try fileURL(for: key)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let cachedValue = try JSONDecoder().decode(CachedRecognitionCandidate.self, from: Data(contentsOf: fileURL))
            return try cachedValue.recognitionCandidate
        } catch {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    public func store(_ value: RecognitionCandidate, for key: OCRCacheKey) throws {
        let fileURL = try fileURL(for: key)
        let directoryURL = fileURL.deletingLastPathComponent()
        try createDirectoryIfNeeded(at: rootURL)
        try createDirectoryIfNeeded(at: directoryURL)

        let data = try CachedRecognitionCandidate(value).encodedData()
        let temporaryURL = directoryURL.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .withoutOverwriting)

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            do {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            } catch {
                guard fileManager.fileExists(atPath: fileURL.path) else {
                    throw error
                }
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            }
        }
    }

    public func removeAll() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return
        }
        try fileManager.removeItem(at: rootURL)
    }

    private func fileURL(for key: OCRCacheKey) throws -> URL {
        let keyData = try JSONEncoder.sortedKeyEncoder.encode(key)
        let digest = SHA256.hash(data: keyData).hexString
        return rootURL
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(digest).json", isDirectory: false)
    }

    private func createDirectoryIfNeeded(at directoryURL: URL) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }
}

private struct CachedRecognitionCandidate: Codable {
    let orientation: UInt32
    let lines: [TextLine]

    init(_ candidate: RecognitionCandidate) {
        orientation = candidate.orientation.rawValue
        lines = candidate.lines
    }

    var recognitionCandidate: RecognitionCandidate {
        get throws {
            guard let orientation = CGImagePropertyOrientation(rawValue: orientation) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Unknown image orientation")
                )
            }
            return RecognitionCandidate(orientation: orientation, lines: lines)
        }
    }

    func encodedData() throws -> Data {
        try JSONEncoder.sortedKeyEncoder.encode(self)
    }
}

private extension JSONEncoder {
    static var sortedKeyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
