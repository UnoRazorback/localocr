import Foundation
import LocalOCRCore
import LocalOCRIntelligence

extension CLIApplication {
    func runDocumentIntelligence(command: String, arguments: [String]) async throws -> Int32 {
        let options = try ParsedCommandOptions(
            arguments: arguments,
            valueOptions: command == "extract-fields" ? ["--field"] : [],
            flags: ["--json"]
        )
        guard options.positional.count == 1, !options.positional[0].isEmpty else {
            throw CLIArgumentError.message("\(command) requires one file")
        }
        let fields = options.values["--field", default: []].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if command == "extract-fields" {
            guard (1...32).contains(fields.count), Set(fields).count == fields.count,
                  fields.allSatisfy({ !$0.isEmpty && $0.count <= 128 && !$0.hasPrefix("--") }) else {
                throw CLIArgumentError.message("--field requires 1 through 32 unique, nonempty names of at most 128 characters")
            }
        }
        guard let intelligence else { throw IntelligenceError.bridgeUnavailable }
        let url = URL(fileURLWithPath: options.positional[0]).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw OneShotInputError.fileNotFound }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw OneShotInputError.fileNotReadable }
        let hash = try await FileHashing.sha256(of: url)
        let document = try await textLoader.load(url)
        try Task.checkCancellation()
        switch command {
        case "summarize":
            let result = try await intelligence.summarize(document)
            try await finish(SummarizeDocumentResponse(result), url: url, hash: hash)
        case "organize":
            let result = try await intelligence.organize(document)
            try await finish(OrganizeDocumentResponse(result), url: url, hash: hash)
        default:
            let result = try await intelligence.extract(fields, from: document)
            try await finish(ExtractDocumentFieldsResponse(result), url: url, hash: hash)
        }
        return 0
    }

    private func finish<Response: Encodable>(_ response: Response, url: URL, hash: String) async throws {
        try Task.checkCancellation()
        guard try await FileHashing.sha256(of: url) == hash else {
            throw CLIArgumentError.message("source_changed")
        }
        writeJSON(SourcedIntelligenceResponse(value: response, sourcePath: url.path, sourceSHA256: hash))
    }
}

private struct SourcedIntelligenceResponse<Value: Encodable>: Encodable {
    let value: Value
    let sourcePath: String
    let sourceSHA256: String
    enum CodingKeys: String, CodingKey { case sourcePath = "source_path", sourceSHA256 = "source_sha256" }
    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourcePath, forKey: .sourcePath)
        try c.encode(sourceSHA256, forKey: .sourceSHA256)
    }
}

private enum OneShotInputError: Error, CustomStringConvertible {
    case fileNotFound, fileNotReadable
    var description: String {
        switch self {
        case .fileNotFound: "file_not_found"
        case .fileNotReadable: "file_not_readable"
        }
    }
}
