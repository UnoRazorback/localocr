@preconcurrency import Vision
import CoreGraphics
import ImageIO

public struct RecognitionCandidate: Sendable, Equatable {
    public let orientation: CGImagePropertyOrientation
    public let lines: [TextLine]

    public init(orientation: CGImagePropertyOrientation, lines: [TextLine]) {
        self.orientation = orientation
        self.lines = lines
    }

    public var text: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

public protocol TextRecognizing: Sendable {
    func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate
}

struct VisionRecognitionError: Error, LocalizedError, Sendable, Equatable {
    let message: String

    var errorDescription: String? {
        message
    }
}

public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        try await withCheckedThrowingContinuation { continuation in
            let request = Self.makeRequest(settings: settings) { request, error in
                if let error {
                    continuation.resume(throwing: Self.recognitionError(error))
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { observation -> TextLine? in
                    guard let candidate = observation.topCandidates(1).first else {
                        return nil
                    }
                    return TextLine(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        boundingBox: observation.boundingBox
                    )
                }
                continuation.resume(returning: RecognitionCandidate(orientation: orientation, lines: lines))
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
                } catch {
                    continuation.resume(throwing: Self.recognitionError(error))
                }
            }
        }
    }

    static func makeRequest(
        settings: RecognitionSettings,
        completion: @escaping (VNRequest, (any Error)?) -> Void = { _, _ in }
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest(completionHandler: completion)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = settings.usesLanguageCorrection
        if !settings.recognitionLanguages.isEmpty {
            request.recognitionLanguages = settings.recognitionLanguages
        }
        return request
    }

    static func recognitionError(_ error: any Error) -> VisionRecognitionError {
        VisionRecognitionError(message: error.localizedDescription)
    }
}
