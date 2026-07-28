import fitz

from ocr_service import pdf_utils


def _rasterize_page_bytes(path: str, page_index: int, dpi: int = 250) -> bytes:
    doc = fitz.open(path)
    try:
        return pdf_utils.rasterize_page(doc, page_index, dpi)
    finally:
        doc.close()


def test_make_searchable_pdf_adds_text_without_changing_appearance(image_only_pdf, tmp_path):
    path, expected_text = image_only_pdf
    output_path = str(tmp_path / "output_searchable.pdf")

    before_pixels = _rasterize_page_bytes(path, 0)
    failed_pages = pdf_utils.make_searchable_pdf(path, output_path, dpi=250)
    after_pixels = _rasterize_page_bytes(output_path, 0)

    assert failed_pages == []
    # Invisible (render_mode=3) text contributes nothing to the rasterized
    # page, so the visible output must be pixel-identical to the input.
    assert before_pixels == after_pixels

    output_doc = fitz.open(output_path)
    try:
        recovered_text = output_doc[0].get_text()
    finally:
        output_doc.close()
    assert "144,904.17" in recovered_text
    # And it's genuinely searchable, not just present in raw extraction order.
    output_doc = fitz.open(output_path)
    try:
        hits = output_doc[0].search_for("144,904.17")
    finally:
        output_doc.close()
    assert len(hits) >= 1


def test_make_searchable_pdf_skips_native_text_pages_unless_forced(mixed_pdf, tmp_path):
    path, _ = mixed_pdf
    output_path = str(tmp_path / "mixed_searchable.pdf")

    before_native_page_pixels = _rasterize_page_bytes(path, 0)
    pdf_utils.make_searchable_pdf(path, output_path, dpi=250)
    after_native_page_pixels = _rasterize_page_bytes(output_path, 0)

    # Page 1 already had native text — left completely untouched.
    assert before_native_page_pixels == after_native_page_pixels

    output_doc = fitz.open(output_path)
    try:
        page2_text = output_doc[1].get_text()
    finally:
        output_doc.close()
    assert "144,904.17" in page2_text
