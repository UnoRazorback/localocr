import Foundation
import LocalOCRCore
import LocalOCRService
import MCP

public struct MCPToolDispatcher: Sendable {
    private let service: any LocalOCRServing
    private let decoder: MCPArgumentDecoder

    public init(service: any LocalOCRServing, currentDirectory: URL) {
        self.service = service
        decoder = MCPArgumentDecoder(currentDirectory: currentDirectory)
    }

    public func callTool(name: String, arguments: [String: Value]? = nil) async -> CallTool.Result {
        do {
            switch try decoder.decode(toolName: name, arguments: arguments) {
            case let .pageCount(request):
                let response = try await service.pageCount(at: request.fileURL)
                return scalarResult(String(response.pages))
            case let .inspectPDF(request):
                return objectResult(try await service.inspectPDF(at: request.fileURL))
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
            let code = switch error {
            case .unknownTool: "unknown_tool"
            default: "invalid_arguments"
            }
            return errorResult(code: code, message: error.message)
        } catch {
            let mapped = stableError(for: error)
            return errorResult(code: mapped.code, message: mapped.message)
        }
    }

    private func scalarResult(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    private func objectResult<Response: Encodable>(_ response: Response) -> CallTool.Result {
        let data = canonicalJSON(response)
        let text = String(decoding: data, as: UTF8.self)
        do {
            let structuredContent = try JSONDecoder().decode(Value.self, from: data)
            return try CallTool.Result(
                content: [.text(text: text, annotations: nil, _meta: nil)],
                structuredContent: structuredContent
            )
        } catch {
            return errorResult(code: "processing_failed", message: "Unable to encode the OCR response.")
        }
    }

    private func errorResult(code: String, message: String) -> CallTool.Result {
        let data = canonicalJSON(ToolErrorResponse(error: ToolError(code: code, message: message)))
        return CallTool.Result(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private func stableError(for error: any Error) -> (code: String, message: String) {
        if let localError = error as? LocalOCRError {
            return switch localError {
            case .fileNotFound:
                ("file_not_found", "The requested file was not found.")
            case .permissionDenied:
                ("file_not_readable", "The requested file is not readable.")
            case .unsupportedFormat:
                ("unsupported_format", "The file format is not supported.")
            case .unreadablePDF:
                ("invalid_pdf", "The PDF could not be read.")
            case .invalidPageSelection, .pageOutOfBounds:
                ("invalid_page_range", "The requested page range is invalid.")
            case .invalidDestination, .outputValidationFailed:
                ("invalid_output", "The output path is invalid.")
            case .outputExists:
                ("output_exists", "The output file already exists.")
            case .imageDecodeFailed:
                ("image_decode_failed", "The image could not be decoded.")
            case .cancelled:
                ("cancelled", "OCR processing was cancelled.")
            case .rasterizationFailed, .recognitionFailed, .insufficientDiskSpace:
                ("processing_failed", "OCR processing failed.")
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.Code.fileWriteFileExists.rawValue
        {
            return ("output_exists", "The output file already exists.")
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 17 {
            return ("output_exists", "The output file already exists.")
        }
        return ("processing_failed", "OCR processing failed.")
    }

    private func canonicalJSON<Response: Encodable>(_ response: Response) -> Data {
        let encoder = ResponseEncoding.encoder
        encoder.outputFormatting.insert(.withoutEscapingSlashes)
        do {
            return try encoder.encode(response)
        } catch {
            preconditionFailure("MCP responses must always be JSON encodable: \(error)")
        }
    }
}

private struct ToolErrorResponse: Encodable {
    let error: ToolError
}

private struct ToolError: Encodable {
    let code: String
    let message: String
}
