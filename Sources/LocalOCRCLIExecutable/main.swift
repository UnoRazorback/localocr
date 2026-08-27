import Darwin
import Foundation
import LocalOCRCommandKit
import LocalOCRIntelligence
import LocalOCRService

let application = CLIApplication(
    service: LocalOCRService(),
    output: CommandOutput(
        stdout: { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        },
        stderr: { text in
            FileHandle.standardError.write(Data(text.utf8))
        }
    ),
    consentStore: ExternalDataConsentStore(),
    consentIO: StandardConsentCommandIO()
)

let arguments = Array(CommandLine.arguments.dropFirst())
let skipsSurfaceValidation = arguments.isEmpty
    || arguments.contains("--help")
    || arguments.contains("-h")
    || arguments.contains("--version")
    || arguments.contains("-V")

if !skipsSurfaceValidation {
    do {
        _ = try LocalOCRCommandSurface.parseAsRoot(arguments)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(2)
    }
}

let status = await application.run(arguments: arguments)
exit(status)
