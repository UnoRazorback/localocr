import MCP

public enum MCPToolCatalog {
    public static let tools: [Tool] = [
        getPDFPageCount,
        inspectPDF,
        ocrPDF,
        ocrPDFBatch,
        ocrImage,
        makeSearchablePDF,
    ]

    private static let readOnlyAnnotations = Tool.Annotations(
        title: nil,
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    private static let writerAnnotations = Tool.Annotations(
        title: nil,
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false
    )

    private static let localPath: Value = [
        "type": "string",
        "description": "A local absolute or working-directory-relative filesystem path.",
    ]

    private static let dpi: Value = [
        "type": "integer",
        "minimum": 72,
        "maximum": 600,
        "default": 250,
    ]

    private static let pdfOptions: [String: Value] = [
        "page_range": [
            "type": "string",
            "description": "Optional 1-indexed page specification such as 1-5 or 3,7,12.",
        ],
        "dpi": dpi,
        "force_ocr": ["type": "boolean", "default": false],
        "include_lines": ["type": "boolean", "default": false],
    ]

    private static let lineSchema: Value = objectSchema(
        properties: [
            "text": ["type": "string"],
            "confidence": ["type": "number"],
            "x": ["type": "number"],
            "y": ["type": "number"],
            "width": ["type": "number"],
            "height": ["type": "number"],
        ],
        required: ["text", "confidence", "x", "y", "width", "height"]
    )

    private static let pageSchema: Value = objectSchema(
        properties: [
            "page": ["type": "integer"],
            "text": ["type": "string"],
            "method": ["type": "string", "enum": ["existing_text", "vision_ocr"]],
            "lines": ["type": "array", "items": lineSchema],
        ],
        required: ["page", "text", "method"]
    )

    private static let rotatedPageSchema: Value = objectSchema(
        properties: [
            "page": ["type": "integer"],
            "orientation": [
                "type": "string",
                "enum": [
                    "up", "up_mirrored", "down", "down_mirrored",
                    "left", "left_mirrored", "right", "right_mirrored",
                ],
            ],
        ],
        required: ["page", "orientation"]
    )

    private static let pdfResponseProperties: [String: Value] = [
        "source_path": ["type": "string"],
        "source_sha256": ["type": "string"],
        "pages": ["type": "array", "items": pageSchema],
        "failed_pages": ["type": "array", "items": ["type": "integer"]],
        "empty_ocr_pages": ["type": "array", "items": ["type": "integer"]],
        "rotated_ocr_pages": ["type": "array", "items": rotatedPageSchema],
    ]

    private static let pdfResponseRequired = [
        "source_path", "source_sha256", "pages", "failed_pages",
        "empty_ocr_pages", "rotated_ocr_pages",
    ]

    private static let pdfResponseSchema = objectSchema(
        properties: pdfResponseProperties,
        required: pdfResponseRequired
    )

    private static let getPDFPageCount = Tool(
        name: "get_pdf_page_count",
        description: "Return the number of pages in a local PDF.",
        inputSchema: objectSchema(
            properties: ["file_path": localPath],
            required: ["file_path"]
        ),
        annotations: readOnlyAnnotations
    )

    private static let inspectPDF = Tool(
        name: "inspect_pdf",
        description: "Check whether a local PDF has searchable text without running OCR.",
        inputSchema: objectSchema(
            properties: ["file_path": localPath],
            required: ["file_path"]
        ),
        annotations: readOnlyAnnotations,
        outputSchema: objectSchema(
            properties: [
                "source_path": ["type": "string"],
                "source_sha256": ["type": "string"],
                "pages": ["type": "integer"],
                "searchable_pages": ["type": "integer"],
                "ocr_needed_pages": ["type": "integer"],
                "characters": ["type": "integer"],
                "fully_searchable": ["type": "boolean"],
                "page_details": [
                    "type": "array",
                    "items": objectSchema(
                        properties: [
                            "page": ["type": "integer"],
                            "characters": ["type": "integer"],
                            "searchable": ["type": "boolean"],
                        ],
                        required: ["page", "characters", "searchable"]
                    ),
                ],
            ],
            required: [
                "source_path", "source_sha256", "pages", "searchable_pages",
                "ocr_needed_pages", "characters", "fully_searchable", "page_details",
            ]
        )
    )

    private static let makeSearchablePDF = Tool(
        name: "make_searchable_pdf",
        description: "Write a new searchable PDF with recognized text embedded as an invisible text layer.",
        inputSchema: objectSchema(
            properties: [
                "file_path": localPath,
                "output_path": localPath,
                "dpi": dpi,
                "force_ocr": ["type": "boolean", "default": false],
            ],
            required: ["file_path"]
        ),
        annotations: writerAnnotations,
        outputSchema: objectSchema(
            properties: [
                "output_path": ["type": "string"],
                "failed_pages": ["type": "array", "items": ["type": "integer"]],
            ],
            required: ["output_path", "failed_pages"]
        )
    )

    private static let ocrImage = Tool(
        name: "ocr_image",
        description: "OCR a single local image file directly with Apple Vision.",
        inputSchema: objectSchema(
            properties: ["file_path": localPath],
            required: ["file_path"]
        ),
        annotations: readOnlyAnnotations
    )

    private static let ocrPDF = Tool(
        name: "ocr_pdf",
        description: "OCR a local PDF and return recognized text per page.",
        inputSchema: objectSchema(
            properties: ["file_path": localPath].merging(pdfOptions) { _, option in option },
            required: ["file_path"]
        ),
        annotations: readOnlyAnnotations,
        outputSchema: pdfResponseSchema
    )

    private static let ocrPDFBatch = Tool(
        name: "ocr_pdf_batch",
        description: "OCR several local PDFs; one file failure does not abort the batch.",
        inputSchema: objectSchema(
            properties: [
                "file_paths": [
                    "type": "array",
                    "items": localPath,
                    "minItems": 1,
                ],
            ].merging(pdfOptions) { _, option in option },
            required: ["file_paths"]
        ),
        annotations: readOnlyAnnotations,
        outputSchema: objectSchema(
            properties: [
                "processed": ["type": "integer"],
                "succeeded": ["type": "integer"],
                "failed": ["type": "integer"],
                "results": [
                    "type": "array",
                    "items": [
                        "oneOf": [
                            objectSchema(
                                properties: pdfResponseProperties.merging(
                                    ["status": ["const": "ok"]]
                                ) { _, value in value },
                                required: ["status"] + pdfResponseRequired
                            ),
                            objectSchema(
                                properties: [
                                    "status": ["const": "error"],
                                    "source_path": ["type": "string"],
                                    "error": ["type": "string"],
                                ],
                                required: ["status", "source_path", "error"]
                            ),
                        ],
                    ],
                ],
            ],
            required: ["processed", "succeeded", "failed", "results"]
        )
    )

    private static func objectSchema(
        properties: [String: Value],
        required: [String]
    ) -> Value {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": false,
        ])
    }
}
