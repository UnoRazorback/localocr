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
        return Self.linesInReadingOrder(candidate.lines)
            .map(\.text)
            .joined(separator: "\n")
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

    private static func linesInReadingOrder(_ lines: [TextLine]) -> [TextLine] {
        var rows: [[TextLine]] = []

        for line in lines.sorted(by: sortsAsHigherRow) {
            if let rowIndex = rows.firstIndex(where: {
                guard let representative = $0.first else { return false }
                return sharesRow(line, with: representative)
            }) {
                rows[rowIndex].append(line)
            } else {
                rows.append([line])
            }
        }

        return rows.flatMap { row in
            row.sorted(by: sortsFromLeftToRight)
        }
    }

    private static func sharesRow(_ line: TextLine, with representative: TextLine) -> Bool {
        let overlap = min(line.boundingBox.maxY, representative.boundingBox.maxY)
            - max(line.boundingBox.minY, representative.boundingBox.minY)
        let shorterHeight = min(line.boundingBox.height, representative.boundingBox.height)
        return shorterHeight > 0 && overlap / shorterHeight >= 0.5
    }

    private static func sortsAsHigherRow(_ lhs: TextLine, _ rhs: TextLine) -> Bool {
        if lhs.boundingBox.maxY != rhs.boundingBox.maxY {
            return lhs.boundingBox.maxY > rhs.boundingBox.maxY
        }
        if lhs.boundingBox.minY != rhs.boundingBox.minY {
            return lhs.boundingBox.minY > rhs.boundingBox.minY
        }
        return sortsFromLeftToRight(lhs, rhs)
    }

    private static func sortsFromLeftToRight(_ lhs: TextLine, _ rhs: TextLine) -> Bool {
        if lhs.boundingBox.minX != rhs.boundingBox.minX {
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        if lhs.boundingBox.maxX != rhs.boundingBox.maxX {
            return lhs.boundingBox.maxX < rhs.boundingBox.maxX
        }
        if lhs.boundingBox.maxY != rhs.boundingBox.maxY {
            return lhs.boundingBox.maxY > rhs.boundingBox.maxY
        }
        if lhs.text != rhs.text {
            return lhs.text < rhs.text
        }
        return lhs.confidence > rhs.confidence
    }

    private static let imageExtensions: Set<String> = [
        "apng", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]
}
