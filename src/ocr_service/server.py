"""MCP server exposing local Apple-Vision OCR as tools (stdio transport)."""

from . import platform_guard

platform_guard.ensure_macos()

from mcp.server.fastmcp import FastMCP  # noqa: E402

from . import core, pdf_utils, vision_ocr  # noqa: E402
from .cache import OcrCache  # noqa: E402

mcp = FastMCP(
    "ocr-service",
    instructions=(
        "OCR tools for scanned/image-only PDFs and images on macOS, backed by "
        "Apple's Vision framework. Use get_pdf_page_count first on large PDFs "
        "to plan a page_range before running ocr_pdf on the whole document."
    ),
)

_cache = OcrCache()


@mcp.tool()
def get_pdf_page_count(file_path: str) -> int:
    """Return the number of pages in a PDF. Call this before ocr_pdf on large files
    to decide a page_range instead of OCRing the whole document."""
    return pdf_utils.get_page_count(file_path)


@mcp.tool()
def inspect_pdf(file_path: str) -> dict:
    """Check whether a PDF already has searchable text, without running any OCR.

    Returns {"source_path", "source_sha256", "pages", "searchable_pages",
    "ocr_needed_pages", "characters", "fully_searchable", "page_details":
    [{"page", "characters", "searchable"}, ...]}. Call this before ocr_pdf to
    decide whether OCR is even needed, or which pages need it.
    """
    return pdf_utils.inspect_pdf(file_path)


@mcp.tool()
def ocr_pdf(
    file_path: str,
    page_range: str | None = None,
    dpi: int = 250,
    force_ocr: bool = False,
    include_lines: bool = False,
) -> dict:
    """OCR a scanned/image-only PDF and return recognized text per page.

    file_path: path to the PDF.
    page_range: optional 1-indexed page spec, e.g. "1-5" or "3,7,12". Omit for all pages.
    dpi: rasterization resolution; 250-300 recommended for small print in financial documents.
    force_ocr: OCR every requested page even if it already has a native text layer.
        By default, pages with existing digital text are returned as-is (faster, more
        reliable than OCR) instead of being re-recognized.
    include_lines: include per-line confidence and bounding box detail (x/y/width/height,
        normalized 0-1 relative to the page image) alongside each page's plain text.

    Returns {"source_path", "source_sha256",
    "pages": [{"page": int, "text": str, "method": "existing_text"|"vision_ocr",
               "lines": [...] if include_lines}, ...],
    "failed_pages": [int, ...],       # raised an error (corrupt page, undecodable content)
    "empty_ocr_pages": [int, ...],    # OCR ran fine but found no recognizable text
    "rotated_ocr_pages": [{"page", "orientation"}, ...]}  # source pages that weren't upright
    """
    return core.ocr_pdf_pages(
        file_path, page_range, dpi, cache=_cache, force_ocr=force_ocr, include_lines=include_lines
    )


@mcp.tool()
def ocr_pdf_batch(
    file_paths: list[str],
    page_range: str | None = None,
    dpi: int = 250,
    force_ocr: bool = False,
    include_lines: bool = False,
) -> dict:
    """OCR several PDFs in one call. Each file gets its own ocr_pdf-shaped result;
    one file's failure (missing file, corrupt PDF) doesn't abort the rest of the batch.

    Returns {"processed": int, "succeeded": int, "failed": int,
    "results": [<ocr_pdf result, plus "status":"ok"> | {"source_path","status":"error","error"}]}.
    """
    return core.ocr_pdf_batch(
        file_paths, page_range, dpi, cache=_cache, force_ocr=force_ocr, include_lines=include_lines
    )


@mcp.tool()
def ocr_image(file_path: str) -> str:
    """OCR a single image file (PNG/JPG/HEIC/etc.) directly via Vision, no PDF rendering."""
    with open(file_path, "rb") as f:
        image_bytes = f.read()
    return vision_ocr.ocr_image_text(image_bytes)


@mcp.tool()
def make_searchable_pdf(
    file_path: str,
    output_path: str | None = None,
    dpi: int = 250,
    force_ocr: bool = False,
) -> dict:
    """OCR every page lacking a digital text layer and write a new PDF with the
    recognized text embedded as an invisible text layer, so it opens searchable
    in Preview/Acrobat. Pages that already have native text are left untouched
    unless force_ocr=True.

    output_path defaults to the input filename with a "_searchable" suffix.
    Returns {"output_path": str, "failed_pages": [int, ...]} — failed pages are
    copied through unchanged (no text layer) rather than aborting the whole file.
    """
    resolved_output = output_path or pdf_utils.default_searchable_output_path(file_path)
    failed_pages = pdf_utils.make_searchable_pdf(file_path, resolved_output, dpi=dpi, force_ocr=force_ocr)
    return {"output_path": resolved_output, "failed_pages": failed_pages}


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
