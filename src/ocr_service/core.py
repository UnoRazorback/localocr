"""Shared OCR orchestration used by both the MCP server and the CLI."""

import fitz

from . import pdf_utils, vision_ocr
from .cache import OcrCache


def _line_to_dict(line: vision_ocr.TextLine) -> dict:
    return {
        "text": line.text,
        "confidence": line.confidence,
        "x": line.x,
        "y": line.y,
        "width": line.width,
        "height": line.height,
    }


def ocr_pdf_pages(
    file_path: str,
    page_range: str | None,
    dpi: int,
    cache: OcrCache | None = None,
    force_ocr: bool = False,
    include_lines: bool = False,
) -> dict:
    """OCR the requested pages of a PDF, one page at a time, using the cache when available.

    Pages that already carry at least pdf_utils.MIN_NATIVE_CHARS of native
    text are returned as-is (method "existing_text") without invoking Vision,
    unless force_ocr=True — don't OCR content already available digitally.

    Returns:
        {
            "source_path": str,
            "source_sha256": str,
            "pages": [{"page": int, "text": str, "method": "existing_text"|"vision_ocr",
                       "lines": [...]}],  # "lines" only present when include_lines=True
            "failed_pages": [int, ...],       # raised an error (corrupt page, undecodable content)
            "empty_ocr_pages": [int, ...],    # OCR ran fine but found no text (e.g. a photo/blank page)
            "rotated_ocr_pages": [{"page": int, "orientation": str}, ...],  # non-upright source pages
        }
    """
    source_sha256 = pdf_utils.sha256_file(file_path)
    total_pages = pdf_utils.get_page_count(file_path)
    page_indices = pdf_utils.parse_page_range(page_range, total_pages)

    pages_out: list[dict] = []
    failed_pages: list[int] = []
    empty_ocr_pages: list[int] = []
    rotated_ocr_pages: list[dict] = []

    doc = fitz.open(file_path)
    try:
        for idx in page_indices:
            page_num = idx + 1

            if not force_ocr:
                native_text = pdf_utils.get_native_text(doc, idx)
                if len(native_text) >= pdf_utils.MIN_NATIVE_CHARS:
                    page_result = {"page": page_num, "text": native_text, "method": "existing_text"}
                    if include_lines:
                        page_result["lines"] = []
                    pages_out.append(page_result)
                    continue

            cached = cache.get(source_sha256, page_num, dpi) if cache is not None else None
            if cached is not None:
                text = cached["text"]
                orientation = cached.get("orientation", "up")
                lines = cached.get("lines", [])
            else:
                try:
                    png_bytes = pdf_utils.rasterize_page(doc, idx, dpi)
                    result = vision_ocr.ocr_image_lines_best_orientation(png_bytes)
                except Exception:
                    failed_pages.append(page_num)
                    continue

                lines = [_line_to_dict(line) for line in result.lines]
                text = "\n".join(line.text for line in result.lines)
                orientation = result.orientation
                if cache is not None:
                    cache.set(source_sha256, page_num, dpi, {"text": text, "orientation": orientation, "lines": lines})

            if not text.strip():
                empty_ocr_pages.append(page_num)
            if orientation != "up":
                rotated_ocr_pages.append({"page": page_num, "orientation": orientation})

            page_result = {"page": page_num, "text": text, "method": "vision_ocr"}
            if include_lines:
                page_result["lines"] = lines
            pages_out.append(page_result)
    finally:
        doc.close()

    return {
        "source_path": file_path,
        "source_sha256": source_sha256,
        "pages": pages_out,
        "failed_pages": failed_pages,
        "empty_ocr_pages": empty_ocr_pages,
        "rotated_ocr_pages": rotated_ocr_pages,
    }


def ocr_pdf_batch(
    file_paths: list[str],
    page_range: str | None,
    dpi: int,
    cache: OcrCache | None = None,
    force_ocr: bool = False,
    include_lines: bool = False,
) -> dict:
    """OCR several PDFs, one ocr_pdf_pages result per file. A single file's
    failure (missing file, corrupt PDF) is recorded and does not abort the batch.
    """
    results = []
    for file_path in file_paths:
        try:
            result = ocr_pdf_pages(
                file_path, page_range, dpi, cache=cache, force_ocr=force_ocr, include_lines=include_lines
            )
            result["status"] = "ok"
        except Exception as exc:
            result = {"source_path": file_path, "status": "error", "error": str(exc)}
        results.append(result)

    return {
        "processed": len(results),
        "succeeded": sum(1 for r in results if r.get("status") == "ok"),
        "failed": sum(1 for r in results if r.get("status") == "error"),
        "results": results,
    }
