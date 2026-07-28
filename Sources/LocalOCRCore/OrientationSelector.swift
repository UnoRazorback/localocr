import CoreGraphics
import ImageIO

public struct OrientationSelector {
    public init() {}

    public func best(
        image: CGImage,
        settings: RecognitionSettings,
        recognizer: any TextRecognizing
    ) async throws -> RecognitionCandidate {
        let upright = try await recognizer.recognize(
            image: image,
            orientation: .up,
            settings: settings
        )
        let uprightMetrics = metrics(for: upright)
        if uprightMetrics.nonWhitespace >= 12 && uprightMetrics.meanConfidence >= 0.55 {
            return upright
        }

        var bestCandidate = upright
        var bestScore = uprightMetrics.score
        for orientation in [.right, .down, .left] as [CGImagePropertyOrientation] {
            let candidate = try await recognizer.recognize(
                image: image,
                orientation: orientation,
                settings: settings
            )
            let score = metrics(for: candidate).score
            if score > bestScore {
                bestCandidate = candidate
                bestScore = score
            }
        }
        return bestCandidate
    }

    private func metrics(for candidate: RecognitionCandidate) -> (nonWhitespace: Int, meanConfidence: Double, score: Double) {
        let nonWhitespace = candidate.text.filter { !$0.isWhitespace }.count
        let meanConfidence = candidate.lines.isEmpty
            ? 0
            : Double(candidate.lines.map(\.confidence).reduce(0, +) / Float(candidate.lines.count))
        let score = Double(nonWhitespace) * (0.5 + meanConfidence)
        return (nonWhitespace, meanConfidence, score)
    }
}
