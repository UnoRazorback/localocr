import Foundation
import LocalOCRService
import MCP

public enum MCPToolRequest: Sendable, Equatable {
    case pageCount(PageCountRequest)
    case inspectPDF(InspectPDFRequest)
    case ocrPDF(PDFOCRRequest)
    case ocrPDFBatch(BatchOCRRequest)
    case ocrImage(ImageOCRRequest)
    case makeSearchablePDF(SearchablePDFRequest)
}

public enum MCPArgumentError: Error, Sendable, Equatable {
    case unknownTool(String)
    case unknownArgument(String)
    case missingArgument(String)
    case invalidPath(String)
    case invalidPageRange
    case invalidDPI
    case invalidBoolean(String)
    case emptyBatch

    public var message: String {
        switch self {
        case let .unknownTool(name): "unknown tool: \(name)"
        case let .unknownArgument(name): "unknown argument: \(name)"
        case let .missingArgument(name): "\(name) is required"
        case let .invalidPath(name): "\(name) must be a non-empty string path"
        case .invalidPageRange: "page_range must be a string"
        case .invalidDPI: "dpi must be an integer from 72 through 600"
        case let .invalidBoolean(name): "\(name) must be a boolean"
        case .emptyBatch: "file_paths must contain at least one path"
        }
    }
}

public struct MCPArgumentDecoder: Sendable {
    public let currentDirectory: URL

    public init(currentDirectory: URL) {
        self.currentDirectory = currentDirectory.standardizedFileURL
    }

    public func decode(toolName: String, arguments: [String: Value]?) throws -> MCPToolRequest {
        let arguments = arguments ?? [:]
        switch toolName {
        case "get_pdf_page_count":
            try validate(arguments, allowed: ["file_path"])
            return .pageCount(PageCountRequest(fileURL: try path(named: "file_path", in: arguments)))
        case "inspect_pdf":
            try validate(arguments, allowed: ["file_path"])
            return .inspectPDF(InspectPDFRequest(fileURL: try path(named: "file_path", in: arguments)))
        case "ocr_pdf":
            try validate(arguments, allowed: ["file_path", "page_range", "dpi", "force_ocr", "include_lines"])
            return .ocrPDF(try PDFOCRRequest(
                fileURL: path(named: "file_path", in: arguments),
                pageRange: try optionalPageRange(in: arguments),
                dpi: try dpi(in: arguments),
                forceOCR: try bool(named: "force_ocr", default: false, in: arguments),
                includeLines: try bool(named: "include_lines", default: false, in: arguments)
            ))
        case "ocr_pdf_batch":
            try validate(arguments, allowed: ["file_paths", "page_range", "dpi", "force_ocr", "include_lines"])
            return .ocrPDFBatch(try BatchOCRRequest(
                fileURLs: try paths(in: arguments),
                pageRange: try optionalPageRange(in: arguments),
                dpi: try dpi(in: arguments),
                forceOCR: try bool(named: "force_ocr", default: false, in: arguments),
                includeLines: try bool(named: "include_lines", default: false, in: arguments)
            ))
        case "ocr_image":
            try validate(arguments, allowed: ["file_path"])
            return .ocrImage(ImageOCRRequest(fileURL: try path(named: "file_path", in: arguments)))
        case "make_searchable_pdf":
            try validate(arguments, allowed: ["file_path", "output_path", "dpi", "force_ocr"])
            return .makeSearchablePDF(try SearchablePDFRequest(
                fileURL: path(named: "file_path", in: arguments),
                outputURL: try optionalPath(named: "output_path", in: arguments),
                dpi: try dpi(in: arguments),
                forceOCR: try bool(named: "force_ocr", default: false, in: arguments)
            ))
        default:
            throw MCPArgumentError.unknownTool(toolName)
        }
    }

    private func validate(_ arguments: [String: Value], allowed: Set<String>) throws {
        if let unknown = arguments.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw MCPArgumentError.unknownArgument(unknown)
        }
    }

    private func path(named name: String, in arguments: [String: Value]) throws -> URL {
        guard arguments[name] != nil else { throw MCPArgumentError.missingArgument(name) }
        return try optionalPath(named: name, in: arguments) ?? { throw MCPArgumentError.invalidPath(name) }()
    }

    private func optionalPath(named name: String, in arguments: [String: Value]) throws -> URL? {
        guard let value = arguments[name] else { return nil }
        guard case let .string(path) = value, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPArgumentError.invalidPath(name)
        }
        let url = URL(fileURLWithPath: path, relativeTo: currentDirectory)
        return url.standardizedFileURL
    }

    private func paths(in arguments: [String: Value]) throws -> [URL] {
        guard let value = arguments["file_paths"] else { throw MCPArgumentError.missingArgument("file_paths") }
        guard case let .array(values) = value else { throw MCPArgumentError.invalidPath("file_paths") }
        guard !values.isEmpty else { throw MCPArgumentError.emptyBatch }
        return try values.map { value in
            guard case let .string(path) = value, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPArgumentError.invalidPath("file_paths")
            }
            return URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL
        }
    }

    private func optionalPageRange(in arguments: [String: Value]) throws -> String? {
        guard let value = arguments["page_range"] else { return nil }
        guard case let .string(pageRange) = value else { throw MCPArgumentError.invalidPageRange }
        return pageRange
    }

    private func dpi(in arguments: [String: Value]) throws -> Int {
        guard let value = arguments["dpi"] else { return 250 }
        guard case let .int(dpi) = value, (72 ... 600).contains(dpi) else { throw MCPArgumentError.invalidDPI }
        return dpi
    }

    private func bool(named name: String, default defaultValue: Bool, in arguments: [String: Value]) throws -> Bool {
        guard let value = arguments[name] else { return defaultValue }
        guard case let .bool(bool) = value else { throw MCPArgumentError.invalidBoolean(name) }
        return bool
    }
}
