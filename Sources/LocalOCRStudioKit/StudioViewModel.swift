import Foundation
import LocalOCRCore
import Observation

public enum StudioState: Equatable {
    case empty
    case processing(sourceURL: URL, progress: StudioProgress)
    case result(StudioDocumentResult)
    case failure(sourceURL: URL, StudioPresentedError)
}

@MainActor
@Observable
public final class StudioViewModel {
    public private(set) var state: StudioState = .empty

    private let client: any StudioOCRClient
    private var processingTask: Task<Void, Never>?
    private var generation = UUID()
    private var retryURL: URL?

    public init(client: any StudioOCRClient = LocalOCRStudioClient()) {
        self.client = client
    }

    public func open(_ sourceURL: URL) {
        processingTask?.cancel()

        let taskGeneration = UUID()
        generation = taskGeneration
        retryURL = sourceURL
        state = .processing(sourceURL: sourceURL, progress: .inspecting)

        let client = client
        processingTask = Task { [weak self] in
            do {
                let result = try await client.processDocument(at: sourceURL) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.show(progress, for: sourceURL, generation: taskGeneration)
                    }
                }
                self?.show(result, generation: taskGeneration)
            } catch is CancellationError {
                self?.finishCancellation(generation: taskGeneration)
            } catch let error as LocalOCRError where error == .cancelled {
                self?.finishCancellation(generation: taskGeneration)
            } catch {
                self?.show(error, for: sourceURL, generation: taskGeneration)
            }
        }
    }

    public func retry() {
        guard let retryURL else { return }
        open(retryURL)
    }

    public func cancel() {
        processingTask?.cancel()
        processingTask = nil
        generation = UUID()
        retryURL = nil
        state = .empty
    }

    public func clear() {
        cancel()
    }

    private func show(_ progress: StudioProgress, for sourceURL: URL, generation: UUID) {
        guard self.generation == generation,
              case .processing(sourceURL: sourceURL, progress: _) = state
        else {
            return
        }
        state = .processing(sourceURL: sourceURL, progress: progress)
    }

    private func show(_ result: StudioDocumentResult, generation: UUID) {
        guard self.generation == generation else { return }
        processingTask = nil
        state = .result(result)
    }

    private func finishCancellation(generation: UUID) {
        guard self.generation == generation else { return }
        processingTask = nil
        state = .empty
    }

    private func show(_ error: any Error, for sourceURL: URL, generation: UUID) {
        guard self.generation == generation else { return }
        processingTask = nil
        state = .failure(sourceURL: sourceURL, StudioErrorPresentation.present(error))
    }
}
