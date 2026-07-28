import Darwin
import Foundation

enum EngineErrorBoundary {
    case source
    case destination

    var missingFileError: LocalOCRError {
        switch self {
        case .source:
            .fileNotFound
        case .destination:
            .invalidDestination
        }
    }

    var fallbackError: LocalOCRError {
        switch self {
        case .source:
            .unreadablePDF
        case .destination:
            .invalidDestination
        }
    }
}

enum EngineErrorMapper {
    static func validatePDFSourceType(_ url: URL) throws {
        guard url.isFileURL else {
            throw LocalOCRError.unsupportedFormat(
                url.scheme?.lowercased() ?? ""
            )
        }
        let pathExtension = url.pathExtension.lowercased()
        guard pathExtension == "pdf" else {
            throw LocalOCRError.unsupportedFormat(pathExtension)
        }
    }

    static func validateReadablePDFSource(_ url: URL) throws {
        try validatePDFSourceType(url)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
        } catch {
            throw map(error, at: .source)
        }
    }

    static func map(
        _ error: any Error,
        at boundary: EngineErrorBoundary
    ) -> LocalOCRError {
        if let localError = error as? LocalOCRError {
            return localError
        }
        if error is CancellationError {
            return .cancelled
        }
        return knownMapping(error as NSError, at: boundary)
            ?? boundary.fallbackError
    }

    private static func knownMapping(
        _ error: NSError,
        at boundary: EngineErrorBoundary
    ) -> LocalOCRError? {
        if error.domain == NSPOSIXErrorDomain,
           let mapped = mapPOSIX(Int32(error.code), at: boundary)
        {
            return mapped
        }

        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return boundary.missingFileError
            case .fileReadNoPermission,
                 .fileWriteNoPermission,
                 .fileWriteVolumeReadOnly:
                return .permissionDenied
            case .fileWriteOutOfSpace:
                return .insufficientDiskSpace
            case .fileWriteInvalidFileName,
                 .fileReadUnsupportedScheme,
                 .fileWriteUnsupportedScheme:
                return boundary == .destination
                    ? .invalidDestination
                    : .unsupportedFormat("")
            default:
                break
            }
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== error,
           let mapped = knownMapping(underlying, at: boundary)
        {
            return mapped
        }
        return nil
    }

    private static func mapPOSIX(
        _ code: Int32,
        at boundary: EngineErrorBoundary
    ) -> LocalOCRError? {
        switch code {
        case ENOENT:
            boundary.missingFileError
        case EACCES, EPERM, EROFS:
            .permissionDenied
        case ENOSPC, EDQUOT:
            .insufficientDiskSpace
        case ENOTDIR, EISDIR, ENAMETOOLONG, EINVAL, EXDEV, ENOTEMPTY:
            boundary == .destination ? .invalidDestination : nil
        default:
            nil
        }
    }
}
