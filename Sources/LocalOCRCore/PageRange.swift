import Foundation

public enum PageRange {
    public static func validateSyntax(_ selection: String?) throws {
        guard let selection,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        for rawToken in selection.split(separator: ",", omittingEmptySubsequences: false) {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                continue
            }

            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            switch bounds.count {
            case 1:
                _ = try validatePageNumber(String(bounds[0]), selection: selection)
            case 2:
                let lower = try validatePageNumber(String(bounds[0]), selection: selection)
                let upper = try validatePageNumber(String(bounds[1]), selection: selection)
                guard lower <= upper else {
                    throw LocalOCRError.invalidPageSelection(selection)
                }
            default:
                throw LocalOCRError.invalidPageSelection(selection)
            }
        }
    }

    public static func parse(_ selection: String?, totalPages: Int) throws -> [Int] {
        guard let selection,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Array(0..<totalPages)
        }

        var pages = Set<Int>()
        for rawToken in selection.split(separator: ",", omittingEmptySubsequences: false) {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                continue
            }

            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            switch bounds.count {
            case 1:
                pages.insert(try pageNumber(String(bounds[0]), selection: selection, totalPages: totalPages))
            case 2:
                let lower = try pageNumber(String(bounds[0]), selection: selection, totalPages: totalPages)
                let upper = try pageNumber(String(bounds[1]), selection: selection, totalPages: totalPages)
                guard lower <= upper else {
                    throw LocalOCRError.invalidPageSelection(selection)
                }
                pages.formUnion(lower...upper)
            default:
                throw LocalOCRError.invalidPageSelection(selection)
            }
        }

        return pages.sorted()
    }

    private static func pageNumber(_ token: String, selection: String, totalPages: Int) throws -> Int {
        let oneIndexedPage = try validatePageNumber(token, selection: selection)
        guard oneIndexedPage <= totalPages else {
            throw LocalOCRError.pageOutOfBounds(page: oneIndexedPage, total: totalPages)
        }
        return oneIndexedPage - 1
    }

    private static func validatePageNumber(_ token: String, selection: String) throws -> Int {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedToken.allSatisfy(\.isNumber), let oneIndexedPage = Int(trimmedToken), oneIndexedPage > 0 else {
            throw LocalOCRError.invalidPageSelection(selection)
        }
        return oneIndexedPage
    }
}
