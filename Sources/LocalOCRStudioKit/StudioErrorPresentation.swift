import Foundation
import LocalOCRCore

public struct StudioPresentedError: Sendable, Equatable {
    public let title: String
    public let message: String
    public let details: String?

    public init(title: String, message: String, details: String?) {
        self.title = title
        self.message = message
        self.details = details
    }
}

public enum StudioErrorPresentation {
    public static func present(_ error: any Error) -> StudioPresentedError {
        if let error = error as? LocalOCRError {
            return present(error)
        }

        if let error = error as? StudioClientError {
            return switch error {
            case .sourceChanged:
                StudioPresentedError(
                    title: "Document Changed",
                    message: "The document changed while it was being processed. Please open it again.",
                    details: nil
                )
            }
        }

        return StudioPresentedError(
            title: "Couldn’t Process Document",
            message: "The document could not be processed. Please try again.",
            details: "Technical details are hidden to protect your privacy."
        )
    }

    private static func present(_ error: LocalOCRError) -> StudioPresentedError {
        switch error {
        case .fileNotFound:
            StudioPresentedError(
                title: "File Not Found",
                message: "The selected document is no longer available.",
                details: nil
            )
        case .unsupportedFormat:
            StudioPresentedError(
                title: "Unsupported File",
                message: "Choose a PDF or a supported image file.",
                details: nil
            )
        case .imageDecodeFailed, .unreadablePDF:
            StudioPresentedError(
                title: "Couldn’t Read Document",
                message: "This document appears to be damaged or unreadable.",
                details: nil
            )
        case .permissionDenied:
            StudioPresentedError(
                title: "Permission Needed",
                message: "LocalOCR Studio needs permission to read this document.",
                details: nil
            )
        case .invalidPageSelection, .pageOutOfBounds, .rasterizationFailed, .recognitionFailed:
            StudioPresentedError(
                title: "OCR Failed",
                message: "Text recognition could not finish for this document.",
                details: nil
            )
        case .insufficientDiskSpace:
            StudioPresentedError(
                title: "Not Enough Disk Space",
                message: "Free up disk space and try again.",
                details: nil
            )
        case .invalidDestination, .outputValidationFailed:
            StudioPresentedError(
                title: "Choose Another Destination",
                message: "Choose a valid destination for the output file.",
                details: nil
            )
        case .outputExists:
            StudioPresentedError(
                title: "Output Already Exists",
                message: "Choose a new name or destination for the output file.",
                details: nil
            )
        case .cancelled:
            StudioPresentedError(
                title: "Operation Cancelled",
                message: "Document processing was cancelled.",
                details: nil
            )
        }
    }

}
