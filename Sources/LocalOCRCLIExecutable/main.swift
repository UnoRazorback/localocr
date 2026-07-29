import Darwin
import Foundation
import LocalOCRCommandKit
import LocalOCRService

let output = CommandOutput(
    stdout: { text in FileHandle.standardOutput.write(Data(text.utf8)) },
    stderr: { text in FileHandle.standardError.write(Data(text.utf8)) }
)
let status = await CLIApplication(service: LocalOCRService(), output: output)
    .run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
