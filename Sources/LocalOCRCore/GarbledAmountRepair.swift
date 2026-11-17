import CoreGraphics
import Foundation
import ImageIO

/// Finishes amounts whose last digits Vision returned as made-up accented letters.
///
/// On financial pages Vision often reads an amount correctly up to its cents
/// and then returns letters such as "ął" in place of the final digits
/// ("25,740.0ął" for "25,740.00"). Reading the whole page again rarely helps,
/// but reading that one line again, cut out and enlarged, returns the amount
/// cleanly almost every time (`benchmarks/README.md`).
///
/// The repair keeps every character of the amount the first reading saw and
/// takes only the missing digits from the second. It applies only when the
/// second reading is a clean amount that begins with exactly those digits;
/// otherwise the line is left as recognized.
public enum GarbledAmountRepair {
    public static func repaired(
        _ candidate: RecognitionCandidate,
        image: CGImage,
        settings: RecognitionSettings,
        recognizer: any TextRecognizing
    ) async throws -> RecognitionCandidate {
        // Line boxes of a rotated reading are not in the picture's own coordinates.
        guard candidate.orientation == .up else {
            return candidate
        }
        var lines = candidate.lines
        var changed = false
        for index in lines.indices {
            let line = lines[index]
            guard hasGarbledAmount(line.text),
                  let piece = enlargedPiece(of: image, around: line.boundingBox)
            else {
                continue
            }
            try Task.checkCancellation()
            let second: RecognitionCandidate
            do {
                second = try await recognizer.recognize(image: piece, orientation: .up, settings: settings)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LocalOCRError where error == .cancelled {
                throw error
            } catch {
                // The first reading stands.
                continue
            }
            let text = repairedText(line.text, secondReading: second.lines.map(\.text))
            if text != line.text {
                lines[index] = TextLine(text: text, confidence: line.confidence, boundingBox: line.boundingBox)
                changed = true
            }
        }
        return changed ? RecognitionCandidate(orientation: candidate.orientation, lines: lines) : candidate
    }

    // Digits with a decimal point and up to two decimals, then accented Latin letters.
    // Other scripts and signs are left alone: "0.25µm" is a real measurement.
    private static let garbled = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9.,])((?:\d{1,3}(?:,\d{3})+|\d+)\.(\d{0,2}))[À-ɏḀ-ỿ]+"#
    )

    static func hasGarbledAmount(_ text: String) -> Bool {
        guard text.contains(where: { !$0.isASCII }), let garbled else {
            return false
        }
        return garbled.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// `text` with each garbled amount finished from `secondReading`, where a
    /// clean amount there begins with exactly the digits already read.
    static func repairedText(_ text: String, secondReading: [String]) -> String {
        guard let garbled else {
            return text
        }
        let source = text as NSString
        let matches = garbled.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else {
            return text
        }
        var available = secondReading
            .flatMap { AmountVerification.amounts(in: $0) }
            .filter { !$0.isGarbled && $0.value.contains(".") }
            .map(\.value)
        var replacements: [(NSRange, String)] = []
        for match in matches {
            let read = source.substring(with: match.range(at: 1))
            let digits = read.replacingOccurrences(of: ",", with: "")
            let missing = 2 - match.range(at: 2).length
            guard let found = available.firstIndex(where: {
                $0.hasPrefix(digits) && $0.count == digits.count + missing
            }) else {
                continue
            }
            replacements.append((match.range, read + available[found].suffix(missing)))
            available.remove(at: found)
        }
        let result = NSMutableString(string: source)
        for (range, replacement) in replacements.reversed() {
            result.replaceCharacters(in: range, with: replacement)
        }
        return result as String
    }

    /// The line cut out of the page with a little room around it, three times
    /// larger, on a white margin so the text does not touch the picture's edge.
    static func enlargedPiece(of image: CGImage, around box: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // Vision geometry has its origin at the bottom-left corner; pictures at the top-left.
        let line = CGRect(
            x: box.minX * width,
            y: (1 - box.maxY) * height,
            width: box.width * width,
            height: box.height * height
        )
        guard line.width.isFinite, line.height.isFinite, line.width >= 1, line.height >= 1 else {
            return nil
        }
        let area = line
            .insetBy(dx: -0.05 * line.height, dy: -0.1 * line.height)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            .integral
        guard !area.isEmpty, let piece = image.cropping(to: area) else {
            return nil
        }
        let scale: CGFloat = 3
        let margin = (area.height * scale).rounded()
        let pieceSize = CGSize(width: area.width * scale, height: area.height * scale)
        let pixelsWide = Int(pieceSize.width + margin * 2)
        let pixelsHigh = Int(pieceSize.height + margin * 2)
        // A line is never this large; refuse rather than allocate a huge picture.
        guard pixelsWide > 0, pixelsHigh > 0, pixelsWide <= 40_000, pixelsHigh <= 8_000,
              let context = CGContext(
                  data: nil,
                  width: pixelsWide,
                  height: pixelsHigh,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else {
            return nil
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.interpolationQuality = .high
        context.draw(piece, in: CGRect(origin: CGPoint(x: margin, y: margin), size: pieceSize))
        return context.makeImage()
    }
}
