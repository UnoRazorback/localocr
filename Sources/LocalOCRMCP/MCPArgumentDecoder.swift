import Foundation
import LocalOCRService
import MCP

public struct MCPArgumentError: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public enum MCPToolRequest: Sendable, Equatable {
    case getPDFPageCount(URL)
    case inspectPDF(URL)
    case ocrPDF(PDFOCRRequest)
    case ocrPDFBatch(BatchOCRRequest)
    case ocrImage(ImageOCRRequest)
    case makeSearchablePDF(SearchablePDFRequest)
}

public struct MCPArgumentDecoder: Sendable {
    private let currentDirectory: URL

    public init(currentDirectory: URL) {
        self.currentDirectory = currentDirectory.standardizedFileURL
    }

    public func decode(
        name: String,
        arguments: [String: Value]
    ) throws -> MCPToolRequest {
        switch name {
        case "get_pdf_page_count":
            try rejectUnknown(arguments, allowed: ["file_path"])
            return .getPDFPageCount(try path(named: "file_path", in: arguments))
        case "inspect_pdf":
            try rejectUnknown(arguments, allowed: ["file_path"])
            return .inspectPDF(try path(named: "file_path", in: arguments))
        case "ocr_pdf":
            try rejectUnknown(
                arguments,
                allowed: ["file_path", "page_range", "dpi", "force_ocr", "include_lines"]
            )
            return .ocrPDF(
                try PDFOCRRequest(
                    fileURL: path(named: "file_path", in: arguments),
                    pageRange: optionalString(named: "page_range", in: arguments),
                    dpi: dpi(in: arguments),
                    forceOCR: boolean(named: "force_ocr", in: arguments, default: false),
                    includeLines: boolean(named: "include_lines", in: arguments, default: false)
                )
            )
        case "ocr_pdf_batch":
            try rejectUnknown(
                arguments,
                allowed: ["file_paths", "page_range", "dpi", "force_ocr", "include_lines"]
            )
            return .ocrPDFBatch(
                try BatchOCRRequest(
                    fileURLs: paths(named: "file_paths", in: arguments),
                    pageRange: optionalString(named: "page_range", in: arguments),
                    dpi: dpi(in: arguments),
                    forceOCR: boolean(named: "force_ocr", in: arguments, default: false),
                    includeLines: boolean(named: "include_lines", in: arguments, default: false)
                )
            )
        case "ocr_image":
            try rejectUnknown(arguments, allowed: ["file_path"])
            return .ocrImage(
                ImageOCRRequest(fileURL: try path(named: "file_path", in: arguments))
            )
        case "make_searchable_pdf":
            try rejectUnknown(
                arguments,
                allowed: ["file_path", "output_path", "dpi", "force_ocr"]
            )
            return .makeSearchablePDF(
                try SearchablePDFRequest(
                    fileURL: path(named: "file_path", in: arguments),
                    outputURL: optionalPath(named: "output_path", in: arguments),
                    dpi: dpi(in: arguments),
                    forceOCR: boolean(named: "force_ocr", in: arguments, default: false)
                )
            )
        default:
            throw MCPArgumentError("unknown tool '\(name)'")
        }
    }

    private func rejectUnknown(
        _ arguments: [String: Value],
        allowed: Set<String>
    ) throws {
        if let unknown = arguments.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw MCPArgumentError("unknown argument '\(unknown)'")
        }
    }

    private func path(
        named name: String,
        in arguments: [String: Value]
    ) throws -> URL {
        guard let value = arguments[name] else {
            throw MCPArgumentError("\(name) is required")
        }
        return try decodePath(value, named: name)
    }

    private func optionalPath(
        named name: String,
        in arguments: [String: Value]
    ) throws -> URL? {
        guard let value = arguments[name] else { return nil }
        return try decodePath(value, named: name)
    }

    private func paths(
        named name: String,
        in arguments: [String: Value]
    ) throws -> [URL] {
        guard
            let value = arguments[name],
            case let .array(values) = value,
            !values.isEmpty
        else {
            throw MCPArgumentError("\(name) must be a non-empty array of non-empty strings")
        }

        return try values.map { value in
            guard
                case let .string(path) = value,
                !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw MCPArgumentError("\(name) must be a non-empty array of non-empty strings")
            }
            return resolve(path)
        }
    }

    private func decodePath(_ value: Value, named name: String) throws -> URL {
        guard
            case let .string(path) = value,
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MCPArgumentError("\(name) must be a non-empty string")
        }
        return resolve(path)
    }

    private func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return currentDirectory.appendingPathComponent(path).standardizedFileURL
    }

    private func optionalString(
        named name: String,
        in arguments: [String: Value]
    ) throws -> String? {
        guard let value = arguments[name] else { return nil }
        guard case let .string(string) = value else {
            throw MCPArgumentError("\(name) must be a string")
        }
        return string
    }

    private func dpi(in arguments: [String: Value]) throws -> Int {
        guard let value = arguments["dpi"] else { return 250 }
        let decoded: Int
        switch value {
        case let .int(integer):
            decoded = integer
        case let .double(double)
            where double.isFinite
                && double.rounded(.towardZero) == double
                && (72 ... 600).contains(double):
            decoded = Int(double)
        default:
            throw MCPArgumentError("dpi must be an integer from 72 through 600")
        }
        guard (72 ... 600).contains(decoded) else {
            throw MCPArgumentError("dpi must be an integer from 72 through 600")
        }
        return decoded
    }

    private func boolean(
        named name: String,
        in arguments: [String: Value],
        default defaultValue: Bool
    ) throws -> Bool {
        guard let value = arguments[name] else { return defaultValue }
        guard case let .bool(boolean) = value else {
            throw MCPArgumentError("\(name) must be a boolean")
        }
        return boolean
    }
}
