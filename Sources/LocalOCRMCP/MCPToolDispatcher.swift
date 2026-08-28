import Foundation
import LocalOCRCore
import LocalOCRIntelligence
import LocalOCRService
import MCPStdio

public struct MCPToolDispatcher: Sendable {
    private let service: any LocalOCRServing
    private let textLoader: any DocumentTextLoading
    private let intelligence: any DocumentIntelligenceProviding
    private let consentStore: any ExternalDataConsentStoring
    private let decoder: MCPArgumentDecoder

    public init(
        service: any LocalOCRServing,
        textLoader: any DocumentTextLoading,
        intelligence: any DocumentIntelligenceProviding,
        consentStore: any ExternalDataConsentStoring,
        currentDirectory: URL
    ) {
        self.service = service
        self.textLoader = textLoader
        self.intelligence = intelligence
        self.consentStore = consentStore
        decoder = MCPArgumentDecoder(currentDirectory: currentDirectory)
    }

    public func callTool(name: String, arguments: [String: Value]? = nil) async -> CallTool.Result {
        do {
            try Task.checkCancellation()
            let request = try decoder.decode(toolName: name, arguments: arguments)
            let consentStatus = await consentStore.status()
            guard case let .current(receipt) = consentStatus,
                  receipt.schemaVersion == ExternalDataConsentReceipt.currentSchemaVersion,
                  receipt.policyVersion == ExternalDataConsentReceipt.currentPolicyVersion,
                  receipt.externalProviderRiskAccepted,
                  receipt.documentToolAccessAccepted
            else {
                return errorResult(
                    code: "external_data_acknowledgment_required",
                    message: "Accept the LocalOCR MCP external-data acknowledgment in LocalOCR Studio Help or with `localocr mcp-consent accept`, then retry."
                )
            }
            try Task.checkCancellation()

            let result: CallTool.Result
            switch request {
            case let .pageCount(request):
                let response = try await service.pageCount(at: request.fileURL)
                result = scalarResult(String(response.pages))
            case let .inspectPDF(request):
                result = objectResult(try await service.inspectPDF(at: request.fileURL))
            case let .ocrPDF(request):
                result = objectResult(try await service.ocrPDF(request))
            case let .ocrPDFBatch(request):
                result = objectResult(await service.ocrPDFBatch(request))
            case let .ocrImage(request):
                let response = try await service.ocrImage(request)
                result = scalarResult(response.text)
            case let .makeSearchablePDF(request):
                result = objectResult(try await service.makeSearchablePDF(request))
            case let .summarizeDocument(request):
                let document = try await textLoader.load(request.fileURL)
                try Task.checkCancellation()
                do {
                    result = objectResult(try await intelligence.summarize(document))
                } catch let error as IntelligenceError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw MCPIntelligenceDispatchError.generationFailed
                }
            case let .organizeDocument(request):
                let document = try await textLoader.load(request.fileURL)
                try Task.checkCancellation()
                do {
                    result = objectResult(try await intelligence.organize(document))
                } catch let error as IntelligenceError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw MCPIntelligenceDispatchError.generationFailed
                }
            case let .extractDocumentFields(request):
                let document = try await textLoader.load(request.fileURL)
                try Task.checkCancellation()
                do {
                    result = objectResult(ExtractDocumentFieldsResponse(
                        fields: try await intelligence.extract(request.fields, from: document)
                    ))
                } catch let error as IntelligenceError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw MCPIntelligenceDispatchError.generationFailed
                }
            }
            try Task.checkCancellation()
            return result
        } catch let error as MCPArgumentError {
            let code = switch error {
            case .unknownTool: "unknown_tool"
            default: "invalid_arguments"
            }
            return errorResult(code: code, message: error.message)
        } catch is CancellationError {
            return errorResult(code: "cancelled", message: "OCR processing was cancelled.")
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
            let json = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
            let structuredContent = try literalJSONValue(json)
            return CallTool.Result(
                content: [.text(text: text, annotations: nil, _meta: nil)],
                structuredContent: Optional.some(structuredContent)
            )
        } catch {
            return errorResult(code: "processing_failed", message: "Unable to encode the OCR response.")
        }
    }

    private func literalJSONValue(_ json: Any) throws -> Value {
        if json is NSNull {
            return .null
        }
        if let string = json as? String {
            return .string(string)
        }
        if let number = json as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            if double.rounded(.towardZero) == double,
               double >= Double(Int.min),
               double <= Double(Int.max)
            {
                return .int(number.intValue)
            }
            return .double(double)
        }
        if let array = json as? [Any] {
            return .array(try array.map(literalJSONValue))
        }
        if let object = json as? [String: Any] {
            return .object(try object.mapValues(literalJSONValue))
        }
        throw LiteralJSONValueError.unsupportedType
    }

    private func errorResult(code: String, message: String) -> CallTool.Result {
        let data = canonicalJSON(ToolErrorResponse(error: ToolError(code: code, message: message)))
        return CallTool.Result(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private func stableError(for error: any Error) -> (code: String, message: String) {
        if let intelligenceError = error as? IntelligenceError {
            return stableIntelligenceError(for: intelligenceError)
        }
        if error is MCPIntelligenceDispatchError {
            return (
                "local_intelligence_generation_failed",
                "Local Intelligence could not process this document. Ordinary OCR tools remain available."
            )
        }
        if error is LocalOCRDocumentTextLoaderError {
            return ("unsupported_format", "The file format is not supported.")
        }
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

    private func stableIntelligenceError(for error: IntelligenceError) -> (code: String, message: String) {
        switch error {
        case let .unavailable(availability):
            switch availability {
            case .requiresMacOS26:
                ("local_intelligence_requires_macos_26", "Local Intelligence requires macOS 26 or later. Ordinary OCR tools remain available.")
            case .deviceNotEligible:
                ("local_intelligence_device_not_eligible", "This Mac is not eligible for Apple Intelligence. Ordinary OCR tools remain available.")
            case .appleIntelligenceNotEnabled:
                ("apple_intelligence_not_enabled", "Enable Apple Intelligence in System Settings, then retry. Ordinary OCR tools remain available.")
            case .modelNotReady:
                ("local_intelligence_model_not_ready", "Apple Intelligence is not ready. Finish downloading or preparing the model, then retry. Ordinary OCR tools remain available.")
            case .unsupportedLanguage:
                ("local_intelligence_language_not_supported", "Apple Intelligence does not support this document language. Ordinary OCR tools remain available.")
            case .available:
                ("local_intelligence_generation_failed", "Local Intelligence could not process this document. Ordinary OCR tools remain available.")
            }
        case .emptyDocument, .invalidFields:
            ("local_intelligence_invalid_input", "The document does not contain usable OCR text or the requested fields are invalid. Ordinary OCR tools remain available.")
        case .contextOverflow:
            ("local_intelligence_generation_failed", "Local Intelligence could not process this document. Ordinary OCR tools remain available.")
        case .ungroundedOutput:
            ("local_intelligence_output_not_grounded", "Local Intelligence could not ground its result in the document. Ordinary OCR tools remain available.")
        case .cancelled:
            ("cancelled", "OCR processing was cancelled.")
        }
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

private enum MCPIntelligenceDispatchError: Error {
    case generationFailed
}

private enum LiteralJSONValueError: Error {
    case unsupportedType
}

private struct ExtractDocumentFieldsResponse: Encodable {
    let fields: [ExtractedDocumentField]
}

private struct ToolErrorResponse: Encodable {
    let error: ToolError
}

private struct ToolError: Encodable {
    let code: String
    let message: String
}
