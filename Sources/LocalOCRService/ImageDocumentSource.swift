import CoreGraphics
import Foundation
import ImageIO
import LocalOCRCore

public protocol ImageDocumentRecognizing: Sendable {
    func recognize(
        image: CGImage,
        settings: RecognitionSettings
    ) async throws -> String
}

public struct ImageDocumentSource: ImageDocumentRecognizing {
    private let recognizer: any TextRecognizing

    public init(recognizer: any TextRecognizing = VisionTextRecognizer()) {
        self.recognizer = recognizer
    }

    public func recognize(
        at fileURL: URL,
        settings: RecognitionSettings
    ) async throws -> String {
        try Task.checkCancellation()
        return try await recognize(image: Self.decodeImage(at: fileURL), settings: settings)
    }

    public func recognize(
        image: CGImage,
        settings: RecognitionSettings
    ) async throws -> String {
        let candidate = try await recognizer.recognize(
            image: image,
            orientation: .up,
            settings: settings
        )
        try Task.checkCancellation()
        return candidate.lines.map(\.text).joined(separator: "\n")
    }

    static func decodeImage(at fileURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            let format = fileURL.pathExtension.lowercased()
            if Self.imageExtensions.contains(format) {
                throw LocalOCRError.imageDecodeFailed
            }
            throw LocalOCRError.unsupportedFormat(format)
        }
        guard CGImageSourceGetType(source) != nil else {
            throw LocalOCRError.unsupportedFormat(fileURL.pathExtension.lowercased())
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw LocalOCRError.imageDecodeFailed
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LocalOCRError.imageDecodeFailed
        }
        return image
    }

    private static let imageExtensions: Set<String> = [
        "apng", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]
}
