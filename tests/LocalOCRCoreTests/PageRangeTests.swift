import LocalOCRCore
import Testing

@Test func parsesOneIndexedRanges() throws {
    #expect(try PageRange.parse(nil, totalPages: 5) == [0, 1, 2, 3, 4])
    #expect(try PageRange.parse("1-3,5", totalPages: 5) == [0, 1, 2, 4])
    #expect(try PageRange.parse("3,3,2", totalPages: 5) == [1, 2])
}

@Test func rejectsMalformedAndOutOfBoundsRanges() {
    #expect(throws: LocalOCRError.invalidPageSelection("3-1")) {
        try PageRange.parse("3-1", totalPages: 5)
    }
    #expect(throws: LocalOCRError.pageOutOfBounds(page: 6, total: 5)) {
        try PageRange.parse("6", totalPages: 5)
    }
}
