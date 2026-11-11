@preconcurrency import Vision
import CoreGraphics
import CoreText
import Foundation
import ImageIO

public struct RecognitionCandidate: Sendable, Equatable {
    public let orientation: CGImagePropertyOrientation
    public let lines: [TextLine]

    public init(orientation: CGImagePropertyOrientation, lines: [TextLine]) {
        self.orientation = orientation
        self.lines = lines
    }

    public var text: String {
        TableRowTextAssembler.text(for: lines)
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

/// Coordinates Vision's callback API with Swift concurrency. Vision can report
/// the same failure both through the request completion handler and by throwing
/// from `perform(_:)`; only the first terminal result may resume the continuation.
final class VisionRecognitionOperation: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<RecognitionCandidate, any Error>

    private let lock = NSLock()
    private var continuation: Continuation?
    private var pendingResult: Result<RecognitionCandidate, any Error>?
    private var request: VNRequest?
    private var isFinished = false

    func install(_ continuation: Continuation) {
        let pendingResult: Result<RecognitionCandidate, any Error>?
        lock.lock()
        if isFinished {
            pendingResult = self.pendingResult
            self.pendingResult = nil
        } else {
            self.continuation = continuation
            pendingResult = nil
        }
        lock.unlock()

        if let pendingResult {
            continuation.resume(with: pendingResult)
        }
    }

    func attach(_ request: VNRequest) {
        let shouldCancel: Bool
        lock.lock()
        self.request = request
        shouldCancel = isFinished
        lock.unlock()

        if shouldCancel {
            request.cancel()
        }
    }

    @discardableResult
    func finish(_ result: Result<RecognitionCandidate, any Error>) -> Bool {
        let continuation: Continuation?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }
        isFinished = true
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()

        continuation?.resume(with: result)
        return true
    }

    func cancel() {
        let request: VNRequest?
        lock.lock()
        request = self.request
        lock.unlock()
        request?.cancel()
        finish(.failure(CancellationError()))
    }
}

public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        let candidate = try await Self.performRecognition(
            image: image,
            orientation: orientation,
            settings: settings
        )
        guard candidate.lines.isEmpty else {
            return candidate
        }

        // Some restricted execution environments have returned a successful
        // request with zero observations for every image instead of reporting
        // an error. A known-text probe distinguishes that condition from a
        // genuinely blank page so callers fail closed rather than accept it.
        let probe = try await Self.performRecognition(
            image: Self.makeAvailabilityProbeImage(),
            orientation: .up,
            settings: settings
        )
        guard probe.text.contains("LOCAL OCR READY 123") else {
            throw VisionRecognitionError(
                message: "Apple Vision OCR is unavailable in the current execution environment. Run LocalOCR outside the restricted sandbox and retry."
            )
        }
        return candidate
    }

    static func performRecognition(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        let operation = VisionRecognitionOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                let request = Self.makeRequest(settings: settings) { request, error in
                    if let error {
                        operation.finish(.failure(Self.recognitionError(error)))
                        return
                    }

                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let lines = observations.compactMap { observation -> TextLine? in
                        guard let candidate = observation.topCandidates(1).first else {
                            return nil
                        }
                        return TextLine(
                            text: AmountPunctuation.normalized(candidate.string),
                            confidence: candidate.confidence,
                            boundingBox: observation.boundingBox
                        )
                    }
                    operation.finish(
                        .success(RecognitionCandidate(orientation: orientation, lines: lines))
                    )
                }
                operation.attach(request)

                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
                    } catch {
                        operation.finish(.failure(Self.recognitionError(error)))
                    }
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    static func makeAvailabilityProbeImage() -> CGImage {
        let width = 900
        let height = 180
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        let attributedText = CFAttributedStringCreate(
            nil,
            "LOCAL OCR READY 123" as CFString,
            [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributedText)
        context.textPosition = CGPoint(x: 40, y: 58)
        CTLineDraw(line, context)
        return context.makeImage()!
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
