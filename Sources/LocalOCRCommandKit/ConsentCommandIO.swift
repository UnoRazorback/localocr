import Darwin
import Foundation

public protocol ConsentCommandIO: Sendable {
    var isTerminal: Bool { get }
    func readLine() -> String?
    func stdout(_ text: String)
    func stderr(_ text: String)
}

public struct StandardConsentCommandIO: ConsentCommandIO {
    public init() {}

    public var isTerminal: Bool {
        isatty(STDIN_FILENO) != 0
    }

    public func readLine() -> String? {
        Swift.readLine()
    }

    public func stdout(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    public func stderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
