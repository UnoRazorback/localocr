public enum IntelligenceError: Error, Sendable, Equatable {
    case unavailable(IntelligenceAvailability)
    case emptyDocument
    case invalidFields
    case contextOverflow
    case ungroundedOutput
    case cancelled
}
