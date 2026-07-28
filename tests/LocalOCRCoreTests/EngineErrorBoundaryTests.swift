import Darwin
import Foundation
@testable import LocalOCRCore
import Testing

@Test func mapsDirectFoundationMissingAndReadOnlyErrors() {
    let missing = NSError(
        domain: NSCocoaErrorDomain,
        code: CocoaError.Code.fileReadNoSuchFile.rawValue
    )
    let readOnly = NSError(
        domain: NSCocoaErrorDomain,
        code: CocoaError.Code.fileWriteVolumeReadOnly.rawValue
    )

    #expect(EngineErrorMapper.map(missing, at: .source) == .fileNotFound)
    #expect(
        EngineErrorMapper.map(readOnly, at: .destination)
            == .permissionDenied
    )
}

@Test func directFoundationCodePrecedesContradictoryUnderlyingPOSIXCode() {
    let error = NSError(
        domain: NSCocoaErrorDomain,
        code: CocoaError.Code.fileWriteNoPermission.rawValue,
        userInfo: [
            NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOSPC)
            ),
        ]
    )

    #expect(
        EngineErrorMapper.map(error, at: .destination)
            == .permissionDenied
    )
}
