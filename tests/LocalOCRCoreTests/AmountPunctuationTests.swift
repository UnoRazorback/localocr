@testable import LocalOCRCore
import Testing

@Suite struct AmountPunctuationTests {
    // Catches the real misreading: Vision returns a period where the page has a thousands comma.
    @Test(arguments: [
        ("25.740.00", "25,740.00"),
        ("2.422.457.56", "2,422,457.56"),
        ("1,234.567.89", "1,234,567.89"),
        ("$117.881.23", "$117,881.23"),
        ("(3.042.90)", "(3,042.90)"),
        ("-6.435.00", "-6,435.00"),
        ("Total Labor 32.175.00 $", "Total Labor 32,175.00 $"),
        ("20.723.85 | 3.042.90", "20,723.85 | 3,042.90"),
    ])
    func restoresGroupingCommas(recognized: String, expected: String) {
        #expect(AmountPunctuation.normalized(recognized) == expected)
    }

    // Catches the repair touching text that is not an amount, or changing a digit.
    @Test(arguments: [
        "25,740.00",
        "740.00",
        "3.57",
        "9.20%",
        "192.168.10.5",
        "10.0.0.25",
        "A1.401.02",
        "Detail 5.100.12A",
        "v2.100.25.1",
        "12.31.2026",
        "1.234.5",
        "1.2345.67",
        "1234.567.89",
        "Sheet A1.40",
        "770-478-5111",
        "",
    ])
    func leavesEverythingElseExactlyAsRecognized(recognized: String) {
        #expect(AmountPunctuation.normalized(recognized) == recognized)
    }
}
