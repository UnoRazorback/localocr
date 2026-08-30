public enum IntelligenceError: Error, Sendable, Equatable {
    case unavailable(IntelligenceAvailability)
    case selection(LocalIntelligenceSelectionFailure)
    case emptyDocument
    case invalidFields
    case contextOverflow
    case ungroundedOutput
    case cancelled
}
