import Foundation

public enum LocalOCRRuntime {
    public static let version = "0.3.0"

    public static func cacheURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let configuredPath = environment["LOCALOCR_CACHE_DIR"],
           !configuredPath.isEmpty
        {
            return URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath)
                .standardizedFileURL
        }

        guard let cachesDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        return cachesDirectory
            .appendingPathComponent("com.rayconsulting.localocr", isDirectory: true)
            .appendingPathComponent("ocr-v1", isDirectory: true)
    }
}
