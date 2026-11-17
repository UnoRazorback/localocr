import CoreGraphics
import Foundation
import ImageIO
@testable import LocalOCRCore
import Testing

@Suite struct GarbledAmountRepairTests {
    private static let repairs: [(String, [String], String)] = [
        // The real misreading: cents run into made-up letters, the second look reads them.
        ("25,740.0\u{105}\u{142}", ["25,740.00"], "25,740.00"),
        ("Total Labor 1,200.5\u{142} due", ["Total Labor 1,200.50 due"], "Total Labor 1,200.50 due"),
        ("9,120.\u{105}\u{142}", ["9,120.37"], "9,120.37"),
        // Complete cents with stray letters after them.
        ("6,435.00\u{142}", ["6,435.00"], "6,435.00"),
        // The first reading's own characters are kept; only the missing digits are taken.
        ("25740.0\u{105}", ["25,740.00"], "25740.00"),
        ("$-3,042.9\u{142}\u{142}", ["$-3,042.90"], "$-3,042.90"),
        // Two amounts on one line are each finished from their own match.
        ("1,100.0\u{142} 2,200.5\u{105}", ["1,100.00", "2,200.50"], "1,100.00 2,200.50"),
    ]

    // Catches the repair not finishing an amount the second look read cleanly.
    @Test(arguments: repairs)
    func finishesAnAmountFromTheSecondLook(recognized: String, second: [String], expected: String) {
        #expect(GarbledAmountRepair.repairedText(recognized, secondReading: second) == expected)
    }

    private static let untouched: [(String, [String])] = [
        // A second look that begins differently must never replace digits already read.
        ("25,740.0\u{105}\u{142}", ["25,748.00"]),
        ("25,740.0\u{105}\u{142}", ["5,740.00"]),
        // No clean amount in the second look.
        ("25,740.0\u{105}\u{142}", ["25,740.0\u{142}"]),
        ("25,740.0\u{105}\u{142}", []),
        // More digits than a pair of cents is not this amount.
        ("25,740.0\u{105}", ["25,740.001"]),
        ("6,435.00\u{142}", ["6,435.007"]),
        // Without cents in the second look there is nothing to finish from.
        ("25,740.\u{142}", ["25,740"]),
        // Ordinary text is never touched.
        ("caf\u{E9} 12", ["cafe 12.00"]),
        ("25,740.00", ["25,748.00"]),
        ("0.25\u{B5}m", ["0.25"]),
    ]

    // Catches the repair changing a digit, inventing one, or touching text that is not a garbled amount.
    @Test(arguments: untouched)
    func leavesTheLineAsRecognized(recognized: String, second: [String]) {
        #expect(GarbledAmountRepair.repairedText(recognized, secondReading: second) == recognized)
    }

    // Catches the page path not using the repair, or looking again at lines that need nothing.
    @Test func looksAgainOnlyAtTheGarbledLineAndKeepsItsPlaceOnThePage() async throws {
        let recognizer = PageThenLineRecognizer()
        let page = try #require(blankImage(width: 1000, height: 1000))
        let first = try await recognizer.recognize(image: page, orientation: .up, settings: RecognitionSettings())

        let repaired = try await GarbledAmountRepair.repaired(
            first, image: page, settings: RecognitionSettings(), recognizer: recognizer
        )

        #expect(repaired.lines.map(\.text) == ["Total Labor", "25,740.00", "Retainage", "1,287.00"])
        #expect(repaired.lines.map(\.boundingBox) == first.lines.map(\.boundingBox))
        #expect(repaired.text == "Total Labor | 25,740.00\nRetainage | 1,287.00")
        // One look at the page, one at the single garbled line.
        #expect(recognizer.sizes.count == 2)
        // The line is 100 x 20 pixels: a little room around it, three times larger, on a white margin.
        #expect(recognizer.sizes.last == Size(width: 3 * 102 + 2 * 72, height: 3 * 24 + 2 * 72))
    }

    // Catches cutting the wrong part of the page out for a rotated reading.
    @Test func leavesARotatedReadingAlone() async throws {
        let recognizer = PageThenLineRecognizer()
        let page = try #require(blankImage(width: 1000, height: 1000))
        let rotated = RecognitionCandidate(orientation: .right, lines: [
            TextLine(text: "25,740.0\u{105}\u{142}", confidence: 1, boundingBox: CGRect(x: 0.8, y: 0.6, width: 0.1, height: 0.02)),
        ])

        let repaired = try await GarbledAmountRepair.repaired(
            rotated, image: page, settings: RecognitionSettings(), recognizer: recognizer
        )

        #expect(repaired == rotated)
        #expect(recognizer.sizes.isEmpty)
    }

    // Catches a failed second look losing the line or failing the page.
    @Test func keepsTheFirstReadingWhenTheSecondLookFails() async throws {
        let recognizer = PageThenLineRecognizer(failsOnLines: true)
        let page = try #require(blankImage(width: 1000, height: 1000))
        let first = try await recognizer.recognize(image: page, orientation: .up, settings: RecognitionSettings())

        let repaired = try await GarbledAmountRepair.repaired(
            first, image: page, settings: RecognitionSettings(), recognizer: recognizer
        )

        #expect(repaired == first)
    }
}

private struct Size: Equatable {
    let width: Int
    let height: Int
}

/// Returns a page with one garbled amount for the full picture, and the clean amount for a cut-out line.
private final class PageThenLineRecognizer: TextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Size] = []
    private let failsOnLines: Bool

    init(failsOnLines: Bool = false) {
        self.failsOnLines = failsOnLines
    }

    private func record(_ size: Size) {
        lock.lock()
        seen.append(size)
        lock.unlock()
    }

    var sizes: [Size] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func recognize(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        settings: RecognitionSettings
    ) async throws -> RecognitionCandidate {
        record(Size(width: image.width, height: image.height))
        guard image.width == 1000 else {
            if failsOnLines {
                throw LocalOCRError.recognitionFailed(page: 1, message: "fixture")
            }
            return RecognitionCandidate(orientation: .up, lines: [line("25,740.00", x: 0.2, y: 0.4, width: 0.6)])
        }
        return RecognitionCandidate(orientation: .up, lines: [
            line("Total Labor", x: 0.10, y: 0.60, width: 0.14),
            line("25,740.0\u{105}\u{142}", x: 0.80, y: 0.60, width: 0.10),
            line("Retainage", x: 0.10, y: 0.55, width: 0.12),
            line("1,287.00", x: 0.80, y: 0.55, width: 0.09),
        ])
    }

    private func line(_ text: String, x: Double, y: Double, width: Double) -> TextLine {
        TextLine(text: text, confidence: 1, boundingBox: CGRect(x: x, y: y, width: width, height: 0.02))
    }
}

private func blankImage(width: Int, height: Int) -> CGImage? {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )?.makeImage()
}
