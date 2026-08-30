import Foundation
import LocalOCRModelBridgeKit

let server = ModelBridgeServer(handler: UnimplementedModelBridgeHandler())
await server.run(
    input: .standardInput,
    output: .standardOutput,
    diagnostics: .standardError
)
