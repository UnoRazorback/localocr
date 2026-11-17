import CoreGraphics
@testable import LocalOCRCore
import Testing

@Suite struct AmountVerificationTests {
    // Catches the feature's whole point failing: a misread digit that a second read exposes goes unmarked.
    @Test func marksAnAmountTheSecondReadReadsDifferentlyAndKeepsTheRowTogether() {
        let outcome = AmountVerification.annotatedText(
            first: [
                line("Total Labor", x: 0.10, y: 0.60, width: 0.14),
                line("25,740.00", x: 0.80, y: 0.60, width: 0.10),
            ],
            second: [
                line("Total Labor", x: 0.10, y: 0.601, width: 0.14),
                line("25,748.00", x: 0.801, y: 0.601, width: 0.10),
            ]
        )

        #expect(outcome.text == "Total Labor | 25,740.00 [second read: 25,748.00]")
        #expect(outcome.flaggedAmounts == 1)
    }

    // Catches marks on amounts both reads agree on, including when only the thousands comma differs.
    @Test func leavesAgreedAmountsExactlyAsRecognized() {
        let first = [
            line("Flooring", x: 0.10, y: 0.65, width: 0.14),
            line("20,723.85", x: 0.80, y: 0.65, width: 0.10),
            line("Base", x: 0.10, y: 0.60, width: 0.06),
            line("3,042.90", x: 0.80, y: 0.60, width: 0.09),
        ]
        let second = [
            line("Flooring", x: 0.10, y: 0.65, width: 0.14),
            line("20723.85", x: 0.80, y: 0.65, width: 0.10),
            line("Base", x: 0.10, y: 0.60, width: 0.06),
            line("3,042.90", x: 0.80, y: 0.60, width: 0.09),
        ]

        let outcome = AmountVerification.annotatedText(first: first, second: second)

        #expect(outcome.text == TableRowTextAssembler.text(for: first))
        #expect(outcome.flaggedAmounts == 0)
    }

    // Catches an amount passing as confirmed when the second read found nothing at that spot.
    @Test func marksAnAmountTheSecondReadDidNotSeeAtAll() {
        let outcome = AmountVerification.annotatedText(
            first: [line("Retainage 6,435.00 held", x: 0.10, y: 0.50, width: 0.40)],
            second: [line("6,435.00", x: 0.10, y: 0.20, width: 0.10)]
        )

        #expect(outcome.text == "Retainage 6,435.00 [not confirmed by second read] held")
        #expect(outcome.flaggedAmounts == 1)
    }

    // Catches false marks when the two reads cut one printed line into different pieces.
    @Test func pairsALineWithThePiecesTheOtherReadSplitItInto() {
        let outcome = AmountVerification.annotatedText(
            first: [line("1,000.00 2,000.00", x: 0.50, y: 0.40, width: 0.30)],
            second: [
                line("2,000.00", x: 0.66, y: 0.40, width: 0.14),
                line("1,000.00", x: 0.50, y: 0.40, width: 0.14),
            ]
        )

        #expect(outcome.text == "1,000.00 2,000.00")
        #expect(outcome.flaggedAmounts == 0)
    }

    // Catches a second reading being attached to the wrong amount when it is unclear which one it replaces.
    @Test func offersTheOtherReadingOnlyWhenItIsClearWhichAmountItBelongsTo() {
        let outcome = AmountVerification.annotatedText(
            first: [line("1,100.00 2,200.00", x: 0.50, y: 0.40, width: 0.30)],
            second: [line("1,180.00", x: 0.50, y: 0.40, width: 0.30)]
        )

        #expect(outcome.text ==
            "1,100.00 [not confirmed by second read] 2,200.00 [not confirmed by second read]")
        #expect(outcome.flaggedAmounts == 2)
    }

    // Catches the commonest real misreading going unmarked: cents that run into made-up accented letters.
    @Test func givesAGarbledAmountTheSecondReadsCleanReading() {
        let outcome = AmountVerification.annotatedText(
            first: [
                line("Total Labor", x: 0.10, y: 0.60, width: 0.14),
                line("25,740.0\u{105}\u{142}", x: 0.80, y: 0.60, width: 0.10),
            ],
            second: [
                line("Total Labor", x: 0.10, y: 0.60, width: 0.14),
                line("25,740.00", x: 0.80, y: 0.60, width: 0.10),
            ]
        )

        #expect(outcome.text == "Total Labor | 25,740.0\u{105}\u{142} [second read: 25,740.00]")
        #expect(outcome.flaggedAmounts == 1)
    }

    // Catches a right amount being marked only because the second read garbled its cents.
    @Test func acceptsASecondReadThatGarbledOnlyTheCents() {
        let outcome = AmountVerification.annotatedText(
            first: [line("25,740.00", x: 0.80, y: 0.60, width: 0.10)],
            second: [line("25,740.0\u{142}", x: 0.80, y: 0.60, width: 0.10)]
        )

        #expect(outcome.text == "25,740.00")
        #expect(outcome.flaggedAmounts == 0)
    }

    // Catches a garbled second read vouching for an amount it does not actually begin like.
    @Test func doesNotLetAGarbledSecondReadConfirmADifferentAmount() {
        let outcome = AmountVerification.annotatedText(
            first: [line("25,740.00", x: 0.80, y: 0.60, width: 0.10)],
            second: [line("25,748.0\u{142}", x: 0.80, y: 0.60, width: 0.10)]
        )

        #expect(outcome.text == "25,740.00 [not confirmed by second read]")
        #expect(outcome.flaggedAmounts == 1)
    }

    // Catches a garbled amount passing unmarked when both reads garble it.
    @Test func marksAGarbledAmountNeitherReadCouldFinish() {
        let outcome = AmountVerification.annotatedText(
            first: [line("6,435.0\u{105}\u{142}", x: 0.80, y: 0.60, width: 0.10)],
            second: [line("6,435.0\u{142}", x: 0.80, y: 0.60, width: 0.10)]
        )

        #expect(outcome.text == "6,435.0\u{105}\u{142} [not confirmed by second read]")
        #expect(outcome.flaggedAmounts == 1)
    }

    // Catches dates, versions, addresses and references being treated as amounts and marked.
    private static let amountCases: [(String, [String])] = [
        ("Total 25,740.00 due", ["25,740.00"]),
        ("$117,881.23", ["117,881.23"]),
        ("(3,042.90)", ["3,042.90"]),
        ("740.00 | 12,500", ["740.00", "12,500"]),
        ("12.31.2026", []),
        ("192.168.10.5", []),
        ("v2.100.25.1", []),
        ("Sheet A1.40", []),
        ("770-478-5111", []),
        ("Invoice 20261116", []),
        ("25,740.00\u{142}", ["25,740.00"]),
        ("9,120.5\u{105}\u{142}", ["9,120.5\u{105}\u{142}"]),
        ("caf\u{E9} 12", []),
        ("0.25\u{B5}m", ["0.25"]),
        ("", []),
    ]

    @Test(arguments: amountCases)
    func findsAmountsAndNothingElse(text: String, expected: [String]) {
        #expect(AmountVerification.amounts(in: text).map(\.text) == expected)
    }

    // Catches the second read drifting to a resolution pair that was never measured.
    @Test func secondReadUsesAMeasuredResolutionPair() {
        #expect(AmountVerification.secondReadDPI(for: 250) == 350)
        #expect(AmountVerification.secondReadDPI(for: 300) == 200)
        #expect(AmountVerification.secondReadDPI(for: 600) == 200)
        #expect(AmountVerification.secondReadDPI(for: 72) == 350)
    }

    private func line(
        _ text: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double = 0.02
    ) -> TextLine {
        TextLine(text: text, confidence: 1, boundingBox: CGRect(x: x, y: y, width: width, height: height))
    }
}
