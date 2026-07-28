"""PDF page counting, rasterization, page-range parsing, and searchable-PDF writing."""

import hashlib
from collections.abc import Iterator
from pathlib import Path

import fitz

from . import vision_ocr

# A page with at least this many native characters is treated as already
# searchable and left alone rather than re-OCR'd (matches the project rule:
# don't OCR content already available digitally).
MIN_NATIVE_CHARS = 20


def get_native_text(doc: fitz.Document, page_index: int) -> str:
    return doc[page_index].get_text().strip()


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_pdf(file_path: str, min_native_chars: int = MIN_NATIVE_CHARS) -> dict:
    """Check whether a PDF already has searchable text, without running any OCR.

    Returns page-by-page native character counts plus a source hash, so a
    caller can decide up front which pages (if any) actually need ocr_pdf.
    """
    doc = fitz.open(file_path)
    try:
        page_details = []
        total_characters = 0
        for idx in range(doc.page_count):
            characters = len(get_native_text(doc, idx))
            total_characters += characters
            page_details.append(
                {"page": idx + 1, "characters": characters, "searchable": characters >= min_native_chars}
            )
    finally:
        doc.close()

    searchable_pages = sum(1 for p in page_details if p["searchable"])
    return {
        "source_path": file_path,
        "source_sha256": sha256_file(file_path),
        "pages": len(page_details),
        "searchable_pages": searchable_pages,
        "ocr_needed_pages": len(page_details) - searchable_pages,
        "characters": total_characters,
        "fully_searchable": searchable_pages == len(page_details),
        "page_details": page_details,
    }


def get_page_count(path: str) -> int:
    doc = fitz.open(path)
    try:
        return doc.page_count
    finally:
        doc.close()


def parse_page_range(spec: str | None, total_pages: int) -> list[int]:
    """Parse a 1-indexed page spec ("1-5", "3,7,12", "1-3,7") into sorted 0-indexed page numbers.

    None or an empty string means every page.
    """
    if spec is None or not spec.strip():
        return list(range(total_pages))

    pages: set[int] = set()
    for token in spec.split(","):
        token = token.strip()
        if not token:
            continue
        if "-" in token:
            start_str, end_str = token.split("-", 1)
            try:
                start, end = int(start_str), int(end_str)
            except ValueError:
                raise ValueError(f"Invalid page range token: '{token}'") from None
            if start < 1 or end < start:
                raise ValueError(f"Invalid page range token: '{token}'")
            pages.update(range(start, end + 1))
        else:
            try:
                pages.add(int(token))
            except ValueError:
                raise ValueError(f"Invalid page token: '{token}'") from None

    out_of_range = sorted(n for n in pages if n < 1 or n > total_pages)
    if out_of_range:
        raise ValueError(f"Page(s) {out_of_range} out of range (document has {total_pages} pages)")

    return sorted(n - 1 for n in pages)


def rasterize_page(doc: fitz.Document, page_index: int, dpi: int) -> bytes:
    zoom = dpi / 72.0
    pix = doc[page_index].get_pixmap(matrix=fitz.Matrix(zoom, zoom))
    return pix.tobytes("png")


def iter_page_images(path: str, page_indices: list[int], dpi: int) -> Iterator[tuple[int, bytes]]:
    """Lazily rasterize only the requested (0-indexed) pages, one at a time.

    Yields (1-indexed page number, PNG bytes). The document handle stays open
    for the duration of iteration but only one page's pixmap is held in
    memory at a time, so large multi-hundred-page packages don't need to be
    fully rasterized up front.
    """
    doc = fitz.open(path)
    try:
        for idx in page_indices:
            yield idx + 1, rasterize_page(doc, idx, dpi)
    finally:
        doc.close()


def _fit_fontsize(text: str, target_width_pt: float, max_size: float, fontname: str = "helv") -> float:
    if not text:
        return 1.0
    unit_width = fitz.get_text_length(text, fontname=fontname, fontsize=1)
    if unit_width <= 0:
        return 1.0
    size = target_width_pt / unit_width
    return max(1.0, min(size, max_size))


def make_searchable_pdf(
    file_path: str, output_path: str, dpi: int = 250, force_ocr: bool = False
) -> list[int]:
    """OCR every page lacking digital text and write output_path with recognized text
    as an invisible layer.

    The original page content (the scanned image) is left untouched; text is
    overlaid at render_mode=3 (invisible) so the page looks identical but
    becomes searchable/selectable. Pages that already have at least
    MIN_NATIVE_CHARS of native text are left as-is (not re-OCR'd) unless
    force_ocr=True. Returns the list of 1-indexed pages whose OCR failed
    (those pages are copied through with no text layer).
    """
    doc = fitz.open(file_path)
    failed_pages: list[int] = []
    try:
        scale = 72.0 / dpi
        for idx in range(doc.page_count):
            page = doc[idx]
            if not force_ocr and len(get_native_text(doc, idx)) >= MIN_NATIVE_CHARS:
                continue
            try:
                png_bytes = rasterize_page(doc, idx, dpi)
                lines = vision_ocr.ocr_image_lines(png_bytes)
            except Exception:
                failed_pages.append(idx + 1)
                continue

            img_w_px = page.rect.width * dpi / 72.0
            img_h_px = page.rect.height * dpi / 72.0

            for line in lines:
                if not line.text.strip():
                    continue
                x0_pt = line.x * img_w_px * scale
                x1_pt = (line.x + line.width) * img_w_px * scale
                top_pt = img_h_px * (1 - (line.y + line.height)) * scale
                bottom_pt = img_h_px * (1 - line.y) * scale

                rect_width_pt = max(x1_pt - x0_pt, 1.0)
                box_height_pt = max(bottom_pt - top_pt, 1.0)
                fontsize = _fit_fontsize(line.text, rect_width_pt, max_size=box_height_pt * 1.3)

                try:
                    page.insert_text(
                        (x0_pt, bottom_pt),
                        line.text,
                        fontsize=fontsize,
                        fontname="helv",
                        render_mode=3,
                    )
                except Exception:
                    continue

        doc.save(output_path, garbage=3, deflate=True)
    finally:
        doc.close()
    return failed_pages


def default_searchable_output_path(file_path: str) -> str:
    p = Path(file_path)
    return str(p.with_name(p.stem + "_searchable" + p.suffix))
