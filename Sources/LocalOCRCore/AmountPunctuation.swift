import Foundation

/// Repairs one specific Vision misreading in recognized amounts.
///
/// Vision sometimes reads the thousands comma of a US-format amount as a
/// period, giving "25.740.00" for "25,740.00". A number whose groups are three
/// digits, whose last group is two digits, and which carries a period as a
/// grouping mark is not a valid amount as written, so its grouping marks are
/// restored to commas. Digits are never changed, and anything that could be a
/// reference, version, or address (letters or more digits alongside) is left
/// exactly as recognized.
enum AmountPunctuation {
    // 1-3 digits, one or more groups of three digits, then exactly two decimals.
    private static let candidate = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9.,])\d{1,3}(?:[.,]\d{3})+\.\d{2}(?![.,]?\d)(?![A-Za-z])"#
    )

    static func normalized(_ text: String) -> String {
        // An affected amount has at least two periods; skip everything else cheaply.
        guard text.utf8.reduce(into: 0, { count, byte in if byte == UInt8(ascii: ".") { count += 1 } }) >= 2 else {
            return text
        }
        let source = text as NSString
        guard let matches = candidate?.matches(in: text, range: NSRange(location: 0, length: source.length)),
              !matches.isEmpty
        else {
            return text
        }
        let result = NSMutableString(string: source)
        for match in matches.reversed() {
            // Everything before the final ".dd" is grouping.
            let grouping = NSRange(location: match.range.location, length: match.range.length - 3)
            let original = source.substring(with: grouping)
            guard original.contains(".") else {
                continue
            }
            result.replaceCharacters(in: grouping, with: original.replacingOccurrences(of: ".", with: ","))
        }
        return result as String
    }
}
