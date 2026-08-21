import Foundation

public struct StudioBatchIssue: Sendable, Equatable {
    public let title: String
    public let message: String
    public let details: String?

    public init(title: String, message: String, details: String?) {
        self.title = title
        self.message = message
        self.details = details
    }
}

public struct StudioBatchCandidate: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceURL: URL
    public let standardizedSourceURL: URL
    public let kind: StudioDocumentKind
    public let relativePath: String
    public let outputGroupName: String?

    public init(
        id: UUID,
        sourceURL: URL,
        standardizedSourceURL: URL,
        kind: StudioDocumentKind,
        relativePath: String,
        outputGroupName: String?
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.standardizedSourceURL = standardizedSourceURL
        self.kind = kind
        self.relativePath = relativePath
        self.outputGroupName = outputGroupName
    }
}

public struct StudioBatchSkippedInput: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceURL: URL
    public let reason: StudioBatchIssue

    public init(id: UUID, sourceURL: URL, reason: StudioBatchIssue) {
        self.id = id
        self.sourceURL = sourceURL
        self.reason = reason
    }
}

public struct StudioBatchDiscovery: Sendable, Equatable {
    public let candidates: [StudioBatchCandidate]
    public let skipped: [StudioBatchSkippedInput]
    public let duplicateCount: Int
    public let selectedFolderRoots: [URL]

    public init(
        candidates: [StudioBatchCandidate],
        skipped: [StudioBatchSkippedInput],
        duplicateCount: Int,
        selectedFolderRoots: [URL]
    ) {
        self.candidates = candidates
        self.skipped = skipped
        self.duplicateCount = duplicateCount
        self.selectedFolderRoots = selectedFolderRoots
    }
}

public struct StudioBatchReservation: Sendable, Equatable {
    public let finalURL: URL
    public let outputRoot: URL

    public init(finalURL: URL, outputRoot: URL) {
        self.finalURL = finalURL
        self.outputRoot = outputRoot
    }
}

public enum StudioBatchItemState: Sendable, Equatable {
    case queued
    case processing(StudioProgress)
    case completed(URL)
    case skipped(StudioBatchIssue)
    case failed(StudioBatchIssue)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .queued, .processing:
            false
        case .completed, .skipped, .failed, .cancelled:
            true
        }
    }

    public var isRetryable: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

public struct StudioBatchItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let candidate: StudioBatchCandidate
    public var reservation: StudioBatchReservation
    public var state: StudioBatchItemState

    public init(
        id: UUID,
        candidate: StudioBatchCandidate,
        reservation: StudioBatchReservation,
        state: StudioBatchItemState
    ) {
        self.id = id
        self.candidate = candidate
        self.reservation = reservation
        self.state = state
    }
}

public enum StudioBatchPhase: Sendable, Equatable {
    case empty
    case reviewing
    case processing
    case complete
}

public struct StudioBatchSummary: Sendable, Equatable {
    public let completed: Int
    public let failed: Int
    public let cancelled: Int
    public let skipped: Int

    public init(items: [StudioBatchItem], skippedCount: Int) {
        completed = items.count { item in
            if case .completed = item.state {
                return true
            }
            return false
        }
        failed = items.count { item in
            if case .failed = item.state {
                return true
            }
            return false
        }
        cancelled = items.count { item in
            if case .cancelled = item.state {
                return true
            }
            return false
        }
        skipped = skippedCount + items.count { item in
            if case .skipped = item.state {
                return true
            }
            return false
        }
    }
}
