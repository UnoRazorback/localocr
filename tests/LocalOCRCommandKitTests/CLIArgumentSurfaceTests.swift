import Testing
@testable import LocalOCRCommandKit

@Test func argumentSurfaceParsesEveryCommandAndOption() throws {
    let pageCount = try LocalOCRCommandSurface.parseAsRoot(["page-count", "input.pdf", "--json"])
    #expect((pageCount as? LocalOCRCommandSurface.PageCount)?.file == "input.pdf")
    #expect((pageCount as? LocalOCRCommandSurface.PageCount)?.json == true)

    let inspect = try LocalOCRCommandSurface.parseAsRoot(["inspect", "input.pdf", "--json"])
    #expect((inspect as? LocalOCRCommandSurface.Inspect)?.file == "input.pdf")
    #expect((inspect as? LocalOCRCommandSurface.Inspect)?.json == true)

    let ocr = try LocalOCRCommandSurface.parseAsRoot([
        "ocr", "input.pdf", "--pages", "2-4", "--dpi", "300", "--force-ocr",
        "--detail", "--no-cache", "--json"
    ]) as? LocalOCRCommandSurface.OCR
    #expect(ocr?.file == "input.pdf")
    #expect(ocr?.pages == "2-4")
    #expect(ocr?.dpi == 300)
    #expect(ocr?.forceOCR == true)
    #expect(ocr?.detail == true)
    #expect(ocr?.noCache == true)
    #expect(ocr?.json == true)

    let batch = try LocalOCRCommandSurface.parseAsRoot([
        "batch", "a.pdf", "b.pdf", "--pages", "1", "--dpi", "288", "--force-ocr",
        "--detail", "--no-cache", "--json"
    ]) as? LocalOCRCommandSurface.Batch
    #expect(batch?.files == ["a.pdf", "b.pdf"])
    #expect(batch?.pages == "1")
    #expect(batch?.dpi == 288)
    #expect(batch?.forceOCR == true)
    #expect(batch?.detail == true)
    #expect(batch?.noCache == true)
    #expect(batch?.json == true)

    let image = try LocalOCRCommandSurface.parseAsRoot([
        "image", "input.png", "--language", "en-US", "--language", "fr-FR",
        "--no-language-correction", "--json"
    ]) as? LocalOCRCommandSurface.Image
    #expect(image?.file == "input.png")
    #expect(image?.language == ["en-US", "fr-FR"])
    #expect(image?.noLanguageCorrection == true)
    #expect(image?.json == true)

    let searchable = try LocalOCRCommandSurface.parseAsRoot([
        "searchable", "input.pdf", "--output", "done.pdf", "--dpi", "250",
        "--force-ocr", "--no-cache", "--json"
    ]) as? LocalOCRCommandSurface.Searchable
    #expect(searchable?.file == "input.pdf")
    #expect(searchable?.output == "done.pdf")
    #expect(searchable?.dpi == 250)
    #expect(searchable?.forceOCR == true)
    #expect(searchable?.noCache == true)
    #expect(searchable?.json == true)
}

@Test func argumentSurfaceRejectsUnknownAndMalformedOptions() {
    #expect(throws: (any Error).self) {
        _ = try LocalOCRCommandSurface.parseAsRoot(["ocr", "input.pdf", "--dpi", "not-an-int"])
    }
    #expect(throws: (any Error).self) {
        _ = try LocalOCRCommandSurface.parseAsRoot(["image", "input.png", "--unknown"])
    }
    #expect(throws: (any Error).self) {
        _ = try LocalOCRCommandSurface.parseAsRoot(["batch", "--json"])
    }
}

@Test func argumentSurfaceRegistersMCPConsentCommands() throws {
    _ = try LocalOCRCommandSurface.parseAsRoot(["mcp-consent", "status"])
    _ = try LocalOCRCommandSurface.parseAsRoot(["mcp-consent", "accept"])
    _ = try LocalOCRCommandSurface.parseAsRoot(["mcp-consent", "revoke"])
}

@Test func argumentSurfaceRejectsConsentBypassFlags() {
    #expect(throws: (any Error).self) {
        _ = try LocalOCRCommandSurface.parseAsRoot(["mcp-consent", "accept", "--yes"])
    }
}

@Test func argumentSurfaceRegistersIntelligenceCommandsAndAllowedJSONFlags() throws {
    _ = try LocalOCRCommandSurface.parseAsRoot(["intelligence", "models"])
    _ = try LocalOCRCommandSurface.parseAsRoot(["intelligence", "models", "--json"])
    _ = try LocalOCRCommandSurface.parseAsRoot([
        "intelligence", "test", "ollama", "gemma4:8b", "--json"
    ])
    _ = try LocalOCRCommandSurface.parseAsRoot([
        "intelligence", "select", "ollama", "gemma4:8b"
    ])
    _ = try LocalOCRCommandSurface.parseAsRoot([
        "intelligence", "select", "apple_foundation_models", "SystemLanguageModel.default"
    ])
    _ = try LocalOCRCommandSurface.parseAsRoot(["intelligence", "status", "--json"])
    _ = try LocalOCRCommandSurface.parseAsRoot(["intelligence", "reset", "--json"])
}

@Test func argumentSurfaceRejectsIntelligenceBypassAndProviderManagementCommands() {
    for arguments in [
        ["intelligence", "select", "ollama", "gemma4:8b", "--json"],
        ["intelligence", "select", "ollama", "gemma4:8b", "--yes"],
        ["intelligence", "select", "ollama", "gemma4:8b", "--force"],
        ["intelligence", "select", "ollama", "gemma4:8b", "--noninteractive"],
        ["intelligence", "install", "ollama", "gemma4:8b"],
        ["intelligence", "pull", "ollama", "gemma4:8b"],
        ["intelligence", "delete", "ollama", "gemma4:8b"],
        ["intelligence", "start", "ollama"],
        ["intelligence", "stop", "ollama"],
        ["intelligence", "load", "lm_studio", "model"],
        ["intelligence", "unload", "lm_studio", "model"],
        ["intelligence", "configure", "ollama"]
    ] {
        #expect(throws: (any Error).self) {
            _ = try LocalOCRCommandSurface.parseAsRoot(arguments)
        }
    }
}
