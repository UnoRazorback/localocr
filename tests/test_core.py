from ocr_service import core, pdf_utils, vision_ocr
from ocr_service.cache import OcrCache


def test_native_text_pdf_uses_existing_text_method(native_text_pdf):
    path, expected_text = native_text_pdf
    result = core.ocr_pdf_pages(path, None, 250)
    assert len(result["pages"]) == 1
    page = result["pages"][0]
    assert page["method"] == "existing_text"
    assert page["text"] == expected_text
    assert result["failed_pages"] == []
    assert result["empty_ocr_pages"] == []
    assert result["rotated_ocr_pages"] == []


def test_image_only_pdf_ocrs_and_recovers_text(image_only_pdf):
    path, expected_text = image_only_pdf
    result = core.ocr_pdf_pages(path, None, 250)
    page = result["pages"][0]
    assert page["method"] == "vision_ocr"
    # OCR text may differ slightly in whitespace/casing from the source, but the
    # dollar figure and key words must survive intact.
    assert "144,904.17" in page["text"]
    assert result["failed_pages"] == []
    assert result["empty_ocr_pages"] == []


def test_mixed_pdf_per_page_methods(mixed_pdf):
    path, expected = mixed_pdf
    result = core.ocr_pdf_pages(path, None, 250)
    pages_by_num = {p["page"]: p for p in result["pages"]}
    assert pages_by_num[1]["method"] == "existing_text"
    assert pages_by_num[1]["text"] == expected[1]
    assert pages_by_num[2]["method"] == "vision_ocr"
    assert "144,904.17" in pages_by_num[2]["text"]


def test_sideways_pdf_recovers_text(sideways_pdf):
    path, expected_text = sideways_pdf
    result = core.ocr_pdf_pages(path, None, 250)
    page = result["pages"][0]
    assert page["method"] == "vision_ocr"
    # The whole point of the fixture: text rendered at 90 degrees must still
    # come back correctly, not as garbage or empty.
    assert "retainage" in page["text"].lower()
    assert "fourteen thousand" in page["text"].lower()
    assert page["page"] not in result["failed_pages"]
    assert page["page"] not in result["empty_ocr_pages"]


def test_photo_only_pdf_marks_empty_not_failed(photo_only_pdf):
    result = core.ocr_pdf_pages(photo_only_pdf, None, 250)
    page = result["pages"][0]
    assert page["method"] == "vision_ocr"
    assert page["text"].strip() == ""
    assert result["failed_pages"] == []
    assert result["empty_ocr_pages"] == [1]


def test_force_ocr_overrides_existing_text(native_text_pdf, monkeypatch):
    path, _ = native_text_pdf
    calls = []
    real = vision_ocr.ocr_image_lines_best_orientation

    def counting(image_bytes, try_rotations=True):
        calls.append(1)
        return real(image_bytes, try_rotations=try_rotations)

    monkeypatch.setattr(vision_ocr, "ocr_image_lines_best_orientation", counting)
    result = core.ocr_pdf_pages(path, None, 250, force_ocr=True)
    assert result["pages"][0]["method"] == "vision_ocr"
    assert len(calls) == 1


def test_large_pdf_page_range_only_processes_requested_pages(large_image_only_pdf, monkeypatch):
    processed_indices = []
    original_rasterize = pdf_utils.rasterize_page

    def recording_rasterize(doc, page_index, dpi):
        processed_indices.append(page_index)
        return original_rasterize(doc, page_index, dpi)

    monkeypatch.setattr(pdf_utils, "rasterize_page", recording_rasterize)

    result = core.ocr_pdf_pages(large_image_only_pdf, "1-2", 250)

    assert len(result["pages"]) == 2
    assert processed_indices == [0, 1]  # not all 20 pages


def test_cache_hit_avoids_second_vision_call(image_only_pdf, tmp_path, monkeypatch):
    path, _ = image_only_pdf
    cache = OcrCache(cache_dir=str(tmp_path / "cache"))

    call_count = {"n": 0}
    real = vision_ocr.ocr_image_lines_best_orientation

    def counting(image_bytes, try_rotations=True):
        call_count["n"] += 1
        return real(image_bytes, try_rotations=try_rotations)

    monkeypatch.setattr(vision_ocr, "ocr_image_lines_best_orientation", counting)

    first = core.ocr_pdf_pages(path, None, 250, cache=cache)
    second = core.ocr_pdf_pages(path, None, 250, cache=cache)

    assert call_count["n"] == 1  # second call was served entirely from cache
    assert first["pages"][0]["text"] == second["pages"][0]["text"]


def test_ocr_pdf_batch_isolates_failures(native_text_pdf, image_only_pdf):
    native_path, _ = native_text_pdf
    image_path, _ = image_only_pdf
    missing_path = "/tmp/does-not-exist-ocr-service-test.pdf"

    result = core.ocr_pdf_batch([native_path, image_path, missing_path], None, 250)

    assert result["processed"] == 3
    assert result["succeeded"] == 2
    assert result["failed"] == 1
    statuses = {r.get("source_path"): r.get("status") for r in result["results"]}
    assert statuses[native_path] == "ok"
    assert statuses[image_path] == "ok"
    assert statuses[missing_path] == "error"


def test_include_lines_adds_confidence_and_bbox(image_only_pdf):
    path, _ = image_only_pdf
    result = core.ocr_pdf_pages(path, None, 250, include_lines=True)
    page = result["pages"][0]
    assert "lines" in page
    assert len(page["lines"]) > 0
    line = page["lines"][0]
    assert set(line.keys()) == {"text", "confidence", "x", "y", "width", "height"}
