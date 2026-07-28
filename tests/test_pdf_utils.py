import pytest

from ocr_service import pdf_utils


def test_parse_page_range_none_means_all():
    assert pdf_utils.parse_page_range(None, 5) == [0, 1, 2, 3, 4]


def test_parse_page_range_dash_range():
    assert pdf_utils.parse_page_range("2-4", 10) == [1, 2, 3]


def test_parse_page_range_comma_list():
    assert pdf_utils.parse_page_range("1,3,5", 10) == [0, 2, 4]


def test_parse_page_range_mixed():
    assert pdf_utils.parse_page_range("1-2,5", 10) == [0, 1, 4]


def test_parse_page_range_single():
    assert pdf_utils.parse_page_range("7", 10) == [6]


def test_parse_page_range_out_of_range_raises():
    with pytest.raises(ValueError, match="out of range"):
        pdf_utils.parse_page_range("99", 10)


def test_parse_page_range_invalid_token_raises():
    with pytest.raises(ValueError):
        pdf_utils.parse_page_range("abc", 10)


def test_sha256_file_deterministic_and_distinct(native_text_pdf, image_only_pdf):
    native_path, _ = native_text_pdf
    image_path, _ = image_only_pdf
    assert pdf_utils.sha256_file(native_path) == pdf_utils.sha256_file(native_path)
    assert pdf_utils.sha256_file(native_path) != pdf_utils.sha256_file(image_path)


def test_inspect_pdf_native_is_fully_searchable(native_text_pdf):
    path, _ = native_text_pdf
    result = pdf_utils.inspect_pdf(path)
    assert result["pages"] == 1
    assert result["fully_searchable"] is True
    assert result["ocr_needed_pages"] == 0
    assert result["characters"] > 0
    assert result["source_sha256"] == pdf_utils.sha256_file(path)


def test_inspect_pdf_image_only_needs_ocr(image_only_pdf):
    path, _ = image_only_pdf
    result = pdf_utils.inspect_pdf(path)
    assert result["pages"] == 1
    assert result["fully_searchable"] is False
    assert result["ocr_needed_pages"] == 1
    assert result["characters"] == 0
