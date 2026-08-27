import MCPStdio

public enum MCPToolCatalog {
    public static let tools: [Tool] = [
        Tool(
            name: "get_pdf_page_count",
            description: "Return the number of pages in a PDF. Call this before ocr_pdf on large files to decide a page_range instead of OCRing the whole document.",
            inputSchema: fileInputSchema(),
            annotations: readOnlyAnnotations
        ),
        Tool(
            name: "inspect_pdf",
            description: "Check whether a PDF already has searchable text, without running any OCR.",
            inputSchema: fileInputSchema(),
            annotations: readOnlyAnnotations,
            outputSchema: inspectOutputSchema
        ),
        Tool(
            name: "ocr_pdf",
            description: "OCR a scanned/image-only PDF and return recognized text per page.",
            inputSchema: pdfInputSchema(fileKey: "file_path"),
            annotations: readOnlyAnnotations,
            outputSchema: pdfOCROutputSchema
        ),
        Tool(
            name: "ocr_pdf_batch",
            description: "OCR several PDFs in one call. One file's failure does not abort the rest of the batch.",
            inputSchema: pdfInputSchema(fileKey: "file_paths"),
            annotations: readOnlyAnnotations,
            outputSchema: batchOutputSchema
        ),
        Tool(
            name: "ocr_image",
            description: "OCR a single image file directly via Vision, without PDF rendering.",
            inputSchema: fileInputSchema(),
            annotations: readOnlyAnnotations
        ),
        Tool(
            name: "make_searchable_pdf",
            description: "Write a new PDF with recognized text embedded as an invisible, searchable text layer.",
            inputSchema: searchableInputSchema,
            annotations: Tool.Annotations(
                title: nil,
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: false
            ),
            outputSchema: searchableOutputSchema
        ),
        Tool(
            name: "summarize_document",
            description: "OCR a local PDF or image and produce a grounded summary with page citations using on-device Local Intelligence.",
            inputSchema: fileInputSchema(),
            annotations: readOnlyAnnotations,
            outputSchema: summaryOutputSchema
        ),
        Tool(
            name: "organize_document",
            description: "OCR a local PDF or image and suggest a grounded title, category, and tags using on-device Local Intelligence.",
            inputSchema: fileInputSchema(),
            annotations: readOnlyAnnotations,
            outputSchema: organizationOutputSchema
        ),
        Tool(
            name: "extract_document_fields",
            description: "OCR a local PDF or image and extract only the requested named fields with optional page evidence using on-device Local Intelligence.",
            inputSchema: extractionInputSchema,
            annotations: readOnlyAnnotations,
            outputSchema: extractionOutputSchema
        )
    ]

    private static let pathDescription = "Local absolute or working-directory-relative filesystem path."
    private static let readOnlyAnnotations = Tool.Annotations(
        title: nil,
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    private static func fileInputSchema() -> Value {
        objectSchema(
            properties: ["file_path": pathSchema],
            required: ["file_path"]
        )
    }

    private static func pdfInputSchema(fileKey: String) -> Value {
        let fileSchema: Value = fileKey == "file_paths"
            ? .object([
                "type": "array",
                "description": .string(pathDescription),
                "items": pathSchema,
                "minItems": 1
            ])
            : pathSchema
        return objectSchema(
            properties: [
                fileKey: fileSchema,
                "page_range": .object([
                    "type": "string",
                    "description": "Optional 1-indexed page spec, such as 1-5 or 3,7,12."
                ]),
                "dpi": .object([
                    "type": "integer",
                    "description": "Rasterization resolution in DPI.",
                    "default": 250,
                    "minimum": 72,
                    "maximum": 600
                ]),
                "force_ocr": .object([
                    "type": "boolean",
                    "default": false,
                    "description": "OCR pages even when they already have native text."
                ]),
                "include_lines": .object([
                    "type": "boolean",
                    "default": false,
                    "description": "Include per-line confidence and bounding-box details."
                ])
            ],
            required: [fileKey]
        )
    }

    private static let searchableInputSchema: Value = objectSchema(
        properties: [
            "file_path": pathSchema,
            "output_path": .object([
                "type": "string",
                "description": .string(pathDescription)
            ]),
            "dpi": .object([
                "type": "integer",
                "description": "Rasterization resolution in DPI.",
                "default": 250,
                "minimum": 72,
                "maximum": 600
            ]),
            "force_ocr": .object([
                "type": "boolean",
                "default": false,
                "description": "OCR pages even when they already have native text."
            ])
        ],
        required: ["file_path"]
    )

    private static let extractionInputSchema: Value = objectSchema(
        properties: [
            "file_path": pathSchema,
            "fields": .object([
                "type": "array",
                "description": "Requested field names. Names are trimmed and must remain unique.",
                "items": .object([
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 128
                ]),
                "minItems": 1,
                "maxItems": 32,
                "uniqueItems": true
            ])
        ],
        required: ["file_path", "fields"]
    )

    private static let pathSchema: Value = .object([
        "type": "string",
        "description": .string(pathDescription)
    ])

    private static let inspectOutputSchema = objectSchema(
        properties: [
            "source_path": stringSchema,
            "source_sha256": stringSchema,
            "pages": integerSchema,
            "searchable_pages": integerSchema,
            "ocr_needed_pages": integerSchema,
            "characters": integerSchema,
            "fully_searchable": boolSchema,
            "page_details": .object(["type": "array", "items": pageInspectionSchema])
        ],
        required: ["source_path", "source_sha256", "pages", "searchable_pages", "ocr_needed_pages", "characters", "fully_searchable", "page_details"]
    )

    private static let pdfOCROutputSchema = objectSchema(
        properties: pdfOCRProperties,
        required: pdfOCRRequired
    )

    private static let batchOutputSchema = objectSchema(
        properties: [
            "processed": integerSchema,
            "succeeded": integerSchema,
            "failed": integerSchema,
            "results": .object(["type": "array", "items": .object(["oneOf": .array([batchSuccessSchema, batchFailureSchema])])])
        ],
        required: ["processed", "succeeded", "failed", "results"]
    )

    private static let pdfOCRProperties: [String: Value] = [
        "source_path": stringSchema,
        "source_sha256": stringSchema,
        "pages": .object(["type": "array", "items": ocrPageSchema]),
        "failed_pages": .object(["type": "array", "items": integerSchema]),
        "empty_ocr_pages": .object(["type": "array", "items": integerSchema]),
        "rotated_ocr_pages": .object(["type": "array", "items": rotatedPageSchema])
    ]

    private static let pdfOCRRequired = [
        "source_path", "source_sha256", "pages", "failed_pages", "empty_ocr_pages", "rotated_ocr_pages"
    ]

    private static let batchSuccessSchema: Value = {
        var properties = pdfOCRProperties
        properties["status"] = .object(["const": "ok"])
        return objectSchema(properties: properties, required: ["status"] + pdfOCRRequired)
    }()

    private static let batchFailureSchema = objectSchema(
        properties: [
            "source_path": stringSchema,
            "status": .object(["const": "error"]),
            "error": stringSchema
        ],
        required: ["source_path", "status", "error"]
    )

    private static let searchableOutputSchema = objectSchema(
        properties: ["output_path": stringSchema, "failed_pages": .object(["type": "array", "items": integerSchema])],
        required: ["output_path", "failed_pages"]
    )

    private static let summaryOutputSchema = objectSchema(
        properties: [
            "text": stringSchema,
            "citations": .object(["type": "array", "items": citationSchema])
        ],
        required: ["text", "citations"]
    )

    private static let organizationOutputSchema = objectSchema(
        properties: [
            "title": stringSchema,
            "category": stringSchema,
            "tags": .object(["type": "array", "items": stringSchema]),
            "citations": .object(["type": "array", "items": citationSchema])
        ],
        required: ["title", "category", "tags", "citations"]
    )

    private static let extractionOutputSchema: Value = objectSchema(
        properties: [
            "fields": .object([
                "type": "array",
                "items": objectSchema(
                    properties: [
                        "name": stringSchema,
                        "value": nullable(stringSchema),
                        "source_page": nullable(integerSchema),
                        "evidence": nullable(stringSchema)
                    ],
                    required: ["name", "value", "source_page", "evidence"]
                )
            ])
        ],
        required: ["fields"]
    )

    private static let citationSchema: Value = objectSchema(
        properties: ["page": integerSchema, "quote": stringSchema],
        required: ["page", "quote"]
    )

    private static let pageInspectionSchema: Value = objectSchema(
        properties: ["page": integerSchema, "characters": integerSchema, "searchable": boolSchema],
        required: ["page", "characters", "searchable"]
    )

    private static let ocrPageSchema: Value = objectSchema(
        properties: [
            "page": integerSchema,
            "text": stringSchema,
            "method": .object(["type": "string", "enum": ["existing_text", "vision_ocr"]]),
            "lines": .object(["type": "array", "items": ocrLineSchema])
        ],
        required: ["page", "text", "method"]
    )

    private static let ocrLineSchema: Value = objectSchema(
        properties: [
            "text": stringSchema,
            "confidence": numberSchema,
            "x": numberSchema,
            "y": numberSchema,
            "width": numberSchema,
            "height": numberSchema
        ],
        required: ["text", "confidence", "x", "y", "width", "height"]
    )

    private static let rotatedPageSchema: Value = objectSchema(
        properties: ["page": integerSchema, "orientation": stringSchema],
        required: ["page", "orientation"]
    )

    private static let stringSchema: Value = .object(["type": "string"])
    private static let integerSchema: Value = .object(["type": "integer"])
    private static let numberSchema: Value = .object(["type": "number"])
    private static let boolSchema: Value = .object(["type": "boolean"])

    private static func nullable(_ schema: Value) -> Value {
        .object(["anyOf": .array([schema, .object(["type": "null"])])])
    }

    private static func objectSchema(properties: [String: Value], required: [String]) -> Value {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": false
        ])
    }
}
