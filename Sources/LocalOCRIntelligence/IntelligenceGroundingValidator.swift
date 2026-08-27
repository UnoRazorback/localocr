import Foundation

public enum IntelligenceGroundingValidator {
    public static func validCitations(
        _ citations: [IntelligenceCitation],
        in document: IntelligenceDocument
    ) -> [IntelligenceCitation] {
        citations.filter { citation in
            guard let page = document.pages.first(where: { $0.number == citation.page }) else {
                return false
            }

            return containsNormalized(citation.quote, in: page.text)
        }
    }

    public static func validExtractedFields(
        _ fields: [ExtractedDocumentField],
        in document: IntelligenceDocument
    ) -> [ExtractedDocumentField] {
        fields.map { field in
            guard
                let value = field.value,
                let sourcePage = field.sourcePage,
                let evidence = field.evidence,
                let page = document.pages.first(where: { $0.number == sourcePage }),
                containsNormalized(value, in: page.text),
                containsNormalized(evidence, in: page.text)
            else {
                return ExtractedDocumentField(name: field.name, value: nil, sourcePage: nil, evidence: nil)
            }

            return field
        }
    }

    private static func containsNormalized(_ candidate: String, in text: String) -> Bool {
        let normalizedCandidate = normalized(candidate)
        guard !normalizedCandidate.isEmpty else { return false }
        return normalized(text).contains(normalizedCandidate)
    }

    private static func normalized(_ text: String) -> String {
        var result = ""
        var previousWasWhitespace = false

        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !result.isEmpty && !previousWasWhitespace {
                    result.append(" ")
                }
                previousWasWhitespace = true
            } else {
                result.unicodeScalars.append(scalar)
                previousWasWhitespace = false
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
