import ArgumentParser
import LocalOCRService

/// The executable parses this surface before handing the request to
/// `CLIApplication`, which owns service execution and process-independent exits.
public struct LocalOCRCommandSurface: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "localocr",
        version: LocalOCRRuntime.version,
        subcommands: [
            PageCount.self, Inspect.self, OCR.self, Batch.self, Image.self, Searchable.self,
            MCPConsent.self
        ]
    )

    public init() {}

    public mutating func run() async throws {}

    public struct PageCount: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "page-count")
        @Argument public var file: String
        @Flag(name: .long) public var json = false
        public init() {}
        public mutating func run() async throws {}
    }

    public struct Inspect: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "inspect")
        @Argument public var file: String
        @Flag(name: .long) public var json = false
        public init() {}
        public mutating func run() async throws {}
    }

    public struct OCR: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "ocr")
        @Argument public var file: String
        @Option(name: .long) public var pages: String?
        @Option(name: .long) public var dpi: Int = 250
        @Flag(name: .customLong("force-ocr")) public var forceOCR = false
        @Flag(name: .long) public var detail = false
        @Flag(name: .customLong("no-cache")) public var noCache = false
        @Flag(name: .long) public var json = false
        public init() {}
        public mutating func run() async throws {}
    }

    public struct Batch: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "batch")
        @Argument public var files: [String]
        @Option(name: .long) public var pages: String?
        @Option(name: .long) public var dpi: Int = 250
        @Flag(name: .customLong("force-ocr")) public var forceOCR = false
        @Flag(name: .long) public var detail = false
        @Flag(name: .customLong("no-cache")) public var noCache = false
        @Flag(name: .long) public var json = false
        public init() {}
        public mutating func run() async throws {}
    }

    public struct Image: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "image")
        @Argument public var file: String
        @Option(name: .long) public var language: [String] = []
        @Flag(name: .customLong("no-language-correction")) public var noLanguageCorrection = false
        @Flag(name: .long) public var json = false
        public init() {}
        public mutating func run() async throws {}
    }

    public struct Searchable: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(commandName: "searchable")
        @Argument public var file: String
        @Option(name: .long) public var output: String?
        @Option(name: .long) public var dpi: Int = 250
        @Flag(name: .customLong("force-ocr")) public var forceOCR = false
        @Flag(name: .customLong("no-cache")) public var noCache = false
        @Flag(name: .long) public var json = false
        public init() {}
        public mutating func run() async throws {}
    }

    public struct MCPConsent: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "mcp-consent",
            subcommands: [Status.self, Accept.self, Revoke.self]
        )

        public init() {}

        public mutating func run() async throws {}

        public struct Status: AsyncParsableCommand {
            public init() {}
            public mutating func run() async throws {}
        }

        public struct Accept: AsyncParsableCommand {
            public init() {}
            public mutating func run() async throws {}
        }

        public struct Revoke: AsyncParsableCommand {
            public init() {}
            public mutating func run() async throws {}
        }
    }
}
