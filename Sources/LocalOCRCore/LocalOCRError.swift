public enum LocalOCRError: Error, Sendable, Equatable {
    case fileNotFound
    case unsupportedFormat(String)
    case imageDecodeFailed
    case permissionDenied
    case invalidPageSelection(String)
    case pageOutOfBounds(page: Int, total: Int)
    case unreadablePDF
    case rasterizationFailed(page: Int)
    case recognitionFailed(page: Int, message: String)
    case insufficientDiskSpace
    case invalidDestination
    case outputValidationFailed
    case cancelled
}
