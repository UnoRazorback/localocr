import CoreGraphics
import Foundation

/// Marks recognized amounts that a second read of the same page does not confirm.
///
/// Vision reports full confidence for amounts it has misread, so confidence
/// cannot single them out. Its commonest misreading is an amount whose last
/// digits run into accented letters it made up ("25,740.0ął"). Reading the page
/// again at another resolution usually returns that amount cleanly. The two
/// reads are paired by position on the page; a garbled amount is given the
/// second read's clean reading, and a clean amount the second read does not
/// repeat is marked.
///
/// A mark means "check this against the page", not "this is wrong", and an
/// unmarked amount is not proven right: a digit misread the same way twice
/// passes. Measured results are in `benchmarks/README.md`.
public enum AmountVerification {
    public struct Outcome: Sendable, Equatable {
        public let text: String
        public let flaggedAmounts: Int

        public init(text: String, flaggedAmounts: Int) {
            self.text = text
            self.flaggedAmounts = flaggedAmounts
        }
    }

    public static let unconfirmedMark = "[not confirmed by second read]"

    public static func mark(secondRead amount: String) -> String {
        "[second read: \(amount)]"
    }

    /// The two resolution pairs measured on real documents: 250 with 350, and 300 with 200.
    public static func secondReadDPI(for dpi: Int) -> Int {
        dpi >= 300 ? 200 : 350
    }

    public static func containsAmount(_ lines: [TextLine]) -> Bool {
        lines.contains { !amounts(in: $0.text).isEmpty }
    }

    /// Page text for `first`, with every amount `second` does not repeat marked in place.
    public static func annotatedText(first: [TextLine], second: [TextLine]) -> Outcome {
        var display = first.map(\.text)
        var flagged = 0
        for (index, line) in first.enumerated() {
            let found = amounts(in: line.text)
            guard !found.isEmpty else {
                continue
            }
            let partners = second
                .filter { overlap(line.boundingBox, $0.boundingBox) >= 0.5 }
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let repeated = partners.flatMap { amounts(in: $0.text) }
            let unconfirmed = found.filter { amount in
                !repeated.contains { amount.isRepeated(by: $0) }
            }
            guard !unconfirmed.isEmpty else {
                continue
            }
            var alternatives: [String] = []
            for amount in repeated where !amount.isGarbled
                && !found.contains(where: { !$0.isGarbled && $0.value == amount.value })
                && !alternatives.contains(amount.text)
            {
                alternatives.append(amount.text)
            }
            // Offer the other reading only when it is clear which amount it belongs to.
            let offersAlternatives = alternatives.count == unconfirmed.count
            let annotated = NSMutableString(string: line.text)
            for (position, amount) in unconfirmed.enumerated().reversed() {
                let mark = offersAlternatives ? mark(secondRead: alternatives[position]) : unconfirmedMark
                annotated.insert(" " + mark, at: amount.range.location + amount.range.length)
            }
            display[index] = annotated as String
            flagged += unconfirmed.count
        }
        return Outcome(
            text: TableRowTextAssembler.text(for: first, display: display),
            flaggedAmounts: flagged
        )
    }

    struct Amount: Equatable {
        let text: String
        /// Digits and decimal point only, so "1,250.00" and "1250.00" compare equal.
        let value: String
        let range: NSRange
        /// The amount runs straight into accented letters Vision made up, so its
        /// last digits were not read and `value` is only how the amount begins.
        let isGarbled: Bool

        /// A clean amount is repeated by the same amount, or by a garbled one that
        /// begins the same way and lost no more than its cents. A garbled amount is
        /// never repeated: it needs the other read to say what it is.
        func isRepeated(by other: Amount) -> Bool {
            guard !isGarbled else {
                return false
            }
            guard other.isGarbled else {
                return other.value == value
            }
            return value.hasPrefix(other.value) && value.count - other.value.count <= 2
        }
    }

    // Grouped digits with optional cents, or plain digits with cents. Not part of
    // a longer number, date, version, address or reference.
    private static let pattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9.,])(?:\d{1,3}(?:,\d{3})+(?:\.\d{2})?|\d+\.\d{2})(?![.,]?\d)(?![A-Za-z])"#
    )

    // An amount cut short by non-ASCII letters, which is how Vision returns some
    // amounts. No real amount in an English-language document is written this way.
    private static let garbledPattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9.,])(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{0,2}[\p{L}&&[^\x00-\x7F]]+"#
    )

    static func amounts(in text: String) -> [Amount] {
        guard text.contains(where: \.isNumber), let pattern, let garbledPattern else {
            return []
        }
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        var found = pattern.matches(in: text, range: whole).map { match in
            let matched = source.substring(with: match.range)
            return Amount(
                text: matched,
                value: matched.replacingOccurrences(of: ",", with: ""),
                range: match.range,
                isGarbled: false
            )
        }
        guard text.contains(where: { !$0.isASCII }) else {
            return found
        }
        for match in garbledPattern.matches(in: text, range: whole)
            where !found.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 })
        {
            let matched = source.substring(with: match.range)
            let digits = String(String.UnicodeScalarView(matched.unicodeScalars.prefix { $0.isASCII }))
            found.append(Amount(
                text: matched,
                value: digits.replacingOccurrences(of: ",", with: ""),
                range: match.range,
                isGarbled: true
            ))
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Shared area as a share of the smaller box, so a line split differently
    /// by the two reads still pairs with its pieces.
    static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smallerArea.isFinite, smallerArea > 0 else {
            return 0
        }
        let shared = lhs.intersection(rhs)
        guard !shared.isNull else {
            return 0
        }
        return shared.width * shared.height / smallerArea
    }
}
