"""Synthetic PDF fixtures for the ocr_service test suite.

Built entirely with PyMuPDF (no Pillow/font dependency): insert_text draws
real vector text for "native" pages, get_pixmap rasterizes a page to PNG
bytes for "image-only" pages, and page.set_rotation bakes an actual rotation
into the rendered pixels for the sideways-page fixture.
"""

import fitz
import pytest

NATIVE_TEXT = "Original Contract Sum is $57,508,601.00 per the schedule of values"
IMAGE_TEXT = "Retainage withheld this period totals $144,904.17 exactly"
SIDEWAYS_TEXT = "The quarterly retainage total is fourteen thousand dollars"

PAGE_WIDTH_PT = 600
PAGE_HEIGHT_PT = 200


def _render_text_to_png(text: str, dpi: int = 250, rotate: int = 0) -> tuple[bytes, float, float]:
    """Render `text` on a blank page and rasterize it to PNG bytes.

    Returns (png_bytes, page_width_pt, page_height_pt) for the *rendered*
    page (width/height swap when rotate is 90 or 270).
    """
    doc = fitz.open()
    page = doc.new_page(width=PAGE_WIDTH_PT, height=PAGE_HEIGHT_PT)
    page.insert_text((20, PAGE_HEIGHT_PT / 2), text, fontsize=14)
    if rotate:
        page.set_rotation(rotate)
    zoom = dpi / 72.0
    pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom))
    png_bytes = pix.tobytes("png")
    width_pt, height_pt = page.rect.width, page.rect.height
    if rotate in (90, 270):
        width_pt, height_pt = height_pt, width_pt
    doc.close()
    return png_bytes, width_pt, height_pt


def _render_blank_shape_to_png(dpi: int = 250) -> bytes:
    """A page with visible content but no text at all (a plain filled shape)."""
    doc = fitz.open()
    page = doc.new_page(width=PAGE_WIDTH_PT, height=PAGE_HEIGHT_PT)
    page.draw_rect(fitz.Rect(50, 50, 350, 150), color=(0, 0, 0), fill=(0.6, 0.6, 0.6), width=2)
    zoom = dpi / 72.0
    pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom))
    png_bytes = pix.tobytes("png")
    doc.close()
    return png_bytes


@pytest.fixture
def native_text_pdf(tmp_path):
    """A one-page PDF with a real (extractable) text layer, no image content."""
    doc = fitz.open()
    page = doc.new_page(width=PAGE_WIDTH_PT, height=PAGE_HEIGHT_PT)
    page.insert_text((20, PAGE_HEIGHT_PT / 2), NATIVE_TEXT, fontsize=14)
    path = tmp_path / "native_text.pdf"
    doc.save(str(path))
    doc.close()
    return str(path), NATIVE_TEXT


@pytest.fixture
def image_only_pdf(tmp_path):
    """A one-page PDF whose only content is a rasterized image of text — no text layer."""
    png_bytes, width_pt, height_pt = _render_text_to_png(IMAGE_TEXT)
    doc = fitz.open()
    page = doc.new_page(width=width_pt, height=height_pt)
    page.insert_image(fitz.Rect(0, 0, width_pt, height_pt), stream=png_bytes)
    path = tmp_path / "image_only.pdf"
    doc.save(str(path))
    doc.close()
    return str(path), IMAGE_TEXT


@pytest.fixture
def mixed_pdf(tmp_path):
    """Page 1 has native text; page 2 is image-only (needs OCR)."""
    png_bytes, width_pt, height_pt = _render_text_to_png(IMAGE_TEXT)
    doc = fitz.open()
    page1 = doc.new_page(width=PAGE_WIDTH_PT, height=PAGE_HEIGHT_PT)
    page1.insert_text((20, PAGE_HEIGHT_PT / 2), NATIVE_TEXT, fontsize=14)
    page2 = doc.new_page(width=width_pt, height=height_pt)
    page2.insert_image(fitz.Rect(0, 0, width_pt, height_pt), stream=png_bytes)
    path = tmp_path / "mixed.pdf"
    doc.save(str(path))
    doc.close()
    return str(path), {1: NATIVE_TEXT, 2: IMAGE_TEXT}


@pytest.fixture
def sideways_pdf(tmp_path):
    """A one-page PDF whose image content is genuinely rotated 90 degrees."""
    png_bytes, width_pt, height_pt = _render_text_to_png(SIDEWAYS_TEXT, rotate=90)
    doc = fitz.open()
    page = doc.new_page(width=width_pt, height=height_pt)
    page.insert_image(fitz.Rect(0, 0, width_pt, height_pt), stream=png_bytes)
    path = tmp_path / "sideways.pdf"
    doc.save(str(path))
    doc.close()
    return str(path), SIDEWAYS_TEXT


@pytest.fixture
def photo_only_pdf(tmp_path):
    """A one-page PDF with visible content (a filled shape) but no text at all."""
    png_bytes = _render_blank_shape_to_png()
    doc = fitz.open()
    page = doc.new_page(width=PAGE_WIDTH_PT, height=PAGE_HEIGHT_PT)
    page.insert_image(fitz.Rect(0, 0, PAGE_WIDTH_PT, PAGE_HEIGHT_PT), stream=png_bytes)
    path = tmp_path / "photo_only.pdf"
    doc.save(str(path))
    doc.close()
    return str(path)


@pytest.fixture
def large_image_only_pdf(tmp_path):
    """A 20-page PDF where every page is image-only (needs OCR), for page-range laziness tests."""
    doc = fitz.open()
    for i in range(20):
        text = f"Page number {i + 1} contains line item total forty two dollars"
        png_bytes, width_pt, height_pt = _render_text_to_png(text)
        page = doc.new_page(width=width_pt, height=height_pt)
        page.insert_image(fitz.Rect(0, 0, width_pt, height_pt), stream=png_bytes)
    path = tmp_path / "large.pdf"
    doc.save(str(path))
    doc.close()
    return str(path)
