public enum IntelligenceError: Error, Sendable, Equatable {
    case unavailable(IntelligenceAvailability)
    case selection(LocalIntelligenceSelectionFailure)
    case emptyDocument
    case invalidFields
    case bridgeUnavailable
    case bridgeInvalid
    case generationTimedOut
    case generationFailed
    case contextOverflow
    case malformedOutput
    case ungroundedOutput
    case cancelled
}
