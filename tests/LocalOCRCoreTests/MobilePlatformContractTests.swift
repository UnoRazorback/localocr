import XCTest
@testable import LocalOCRCore

final class MobilePlatformContractTests: XCTestCase {
    func testOCRResultContractRoundTripsWithoutPlatformPaths() throws {
        let result = OCRResult(
            sourceSHA256: "abc",
            pages: [],
            failedPages: [],
            emptyOCRPages: [],
            rotatedOCRPages: [:]
        )
        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["source_sha256"] as? String, "abc")
        XCTAssertNil(json["source_path"])
        XCTAssertEqual(try JSONDecoder().decode(OCRResult.self, from: data), result)
    }
}
