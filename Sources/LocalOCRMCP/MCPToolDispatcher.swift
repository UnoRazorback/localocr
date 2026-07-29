import Foundation
import LocalOCRCore
import LocalOCRService
import MCP

public struct MCPToolDispatcher: Sendable {
    private let service: any LocalOCRServing
    private let argumentDecoder: MCPArgumentDecoder

    public init(
        service: any LocalOCRServing,
        currentDirectory: URL
    ) {
        self.service = service
        argumentDecoder = MCPArgumentDecoder(currentDirectory: currentDirectory)
    }

    public func call(
        name: String,
        arguments: [String: Value]
    ) async -> CallTool.Result {
        do {
            let request = try argumentDecoder.decode(name: name, arguments: arguments)
            switch request {
            case let .getPDFPageCount(fileURL):
                let response = try await service.pageCount(at: fileURL)
                return scalarResult(String(response.pages))
            case let .inspectPDF(fileURL):
                return objectResult(try await service.inspectPDF(at: fileURL))
            case let .ocrPDF(request):
                return objectResult(try await service.ocrPDF(request))
            case let .ocrPDFBatch(request):
                return objectResult(await service.ocrPDFBatch(request))
            case let .ocrImage(request):
                let response = try await service.ocrImage(request)
                return scalarResult(response.text)
            case let .makeSearchablePDF(request):
                return objectResult(try await service.makeSearchablePDF(request))
            }
        } catch let error as MCPArgumentError {
            return errorResult(code: "invalid_arguments", message: error.message)
        } catch is CancellationError {
            return errorResult(code: "cancelled", message: "Operation cancelled")
        } catch let error as LocalOCRError {
            let mapped = map(error)
            return errorResult(code: mapped.code, message: mapped.message)
        } catch {
            return errorResult(code: "processing_failed", message: "OCR processing failed")
        }
    }

    private func scalarResult(_ text: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: nil,
            isError: false
        )
    }

    private func objectResult<Response: Encodable>(_ response: Response) -> CallTool.Result {
        let data = ResponseEncoding.encode(response)
        guard let structured = try? JSONDecoder().decode(Value.self, from: data) else {
            return errorResult(
                code: "processing_failed",
                message: "OCR response could not be encoded"
            )
        }
        return CallTool.Result(
            content: [
                .text(
                    text: String(decoding: data, as: UTF8.self),
                    annotations: nil,
                    _meta: nil
                ),
            ],
            structuredContent: Optional.some(structured),
            isError: false
        )
    }

    private func errorResult(code: String, message: String) -> CallTool.Result {
        let payload = MCPErrorPayload(error: .init(code: code, message: message))
        let data = ResponseEncoding.encode(payload)
        let structured = try? JSONDecoder().decode(Value.self, from: data)
        return CallTool.Result(
            content: [
                .text(
                    text: String(decoding: data, as: UTF8.self),
                    annotations: nil,
                    _meta: nil
                ),
            ],
            structuredContent: structured,
            isError: true
        )
    }

    private func map(_ error: LocalOCRError) -> (code: String, message: String) {
        switch error {
        case .fileNotFound:
            ("file_not_found", "File not found")
        case .permissionDenied:
            ("file_not_readable", "File is not readable")
        case let .unsupportedFormat(format):
            ("unsupported_format", "Unsupported format: \(format)")
        case .unreadablePDF:
            ("invalid_pdf", "PDF is invalid or unreadable")
        case let .invalidPageSelection(selection):
            ("invalid_page_range", "Invalid page range: \(selection)")
        case let .pageOutOfBounds(page, total):
            ("invalid_page_range", "Page \(page) is outside 1 through \(total)")
        case .invalidDestination:
            ("invalid_output", "Invalid output destination")
        case .outputExists:
            ("output_exists", "Output already exists")
        case .imageDecodeFailed:
            ("image_decode_failed", "Image could not be decoded")
        case .cancelled:
            ("cancelled", "Operation cancelled")
        case let .rasterizationFailed(page):
            ("processing_failed", "Could not rasterize page \(page)")
        case let .recognitionFailed(page, message):
            ("processing_failed", "Recognition failed on page \(page): \(message)")
        case .insufficientDiskSpace:
            ("processing_failed", "Insufficient disk space")
        case .outputValidationFailed:
            ("processing_failed", "Output validation failed")
        }
    }
}

private struct MCPErrorPayload: Encodable {
    struct Detail: Encodable {
        let code: String
        let message: String
    }

    let error: Detail
}
