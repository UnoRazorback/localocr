#!/usr/bin/env python3
"""Generate public, deterministic PDF fixtures for LocalOCRCore tests.

This generator intentionally depends only on PyMuPDF.  The text in every
fixture is synthetic so the repository contains no private document data.
"""

from pathlib import Path

import fitz


FIXTURES = Path(__file__).parents[1] / "tests" / "LocalOCRCoreTests" / "Fixtures"
PAGE_RECT = fitz.Rect(0, 0, 612, 792)  # US Letter at 72 points per inch.
CONTRACT_PAGE_RECT = fitz.Rect(0, 0, 600, 200)
NATIVE_TEXT = "Original Contract Sum is $57,508,601.00 per the schedule of values"
IMAGE_TEXT = "Retainage withheld this period totals $144,904.17 exactly"


def save(document: fitz.Document, name: str) -> None:
    document.set_metadata(
        {
            "title": name,
            "author": "LocalOCRCore fixtures",
            "subject": "Synthetic public test data",
            "keywords": "synthetic,fixture",
            "creator": "PyMuPDF",
            "producer": "PyMuPDF",
            "creationDate": "D:20200101000000Z",
            "modDate": "D:20200101000000Z",
        }
    )
    document.save(FIXTURES / name, garbage=4, deflate=True, no_new_id=True)


def rasterized_text_page(
    text: str,
    page_rect: fitz.Rect = PAGE_RECT,
    origin: tuple[float, float] = (72, 144),
    font_size: int = 20,
    dpi: int = 144,
) -> fitz.Pixmap:
    source = fitz.open()
    page = source.new_page(width=page_rect.width, height=page_rect.height)
    page.insert_text(origin, text, fontsize=font_size, fontname="helv")
    scale = dpi / 72
    pixmap = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False)
    source.close()
    return pixmap


def add_image_page(
    document: fitz.Document,
    text: str,
    page_rect: fitz.Rect = PAGE_RECT,
    origin: tuple[float, float] = (72, 144),
    font_size: int = 20,
    dpi: int = 144,
) -> None:
    page = document.new_page(width=page_rect.width, height=page_rect.height)
    page.insert_image(
        page_rect,
        pixmap=rasterized_text_page(
            text,
            page_rect,
            origin,
            font_size,
            dpi,
        ),
    )


def generate() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)

    mixed = fitz.open()
    native_page = mixed.new_page(
        width=CONTRACT_PAGE_RECT.width,
        height=CONTRACT_PAGE_RECT.height,
    )
    native_page.insert_text(
        (20, CONTRACT_PAGE_RECT.height / 2),
        NATIVE_TEXT,
        fontsize=14,
        fontname="helv",
    )
    add_image_page(
        mixed,
        IMAGE_TEXT,
        CONTRACT_PAGE_RECT,
        origin=(20, CONTRACT_PAGE_RECT.height / 2),
        font_size=14,
    )
    save(mixed, "mixed.pdf")
    mixed.close()

    image_only = fitz.open()
    add_image_page(
        image_only,
        IMAGE_TEXT,
        CONTRACT_PAGE_RECT,
        origin=(20, CONTRACT_PAGE_RECT.height / 2),
        font_size=14,
        dpi=250,
    )
    add_image_page(image_only, "Synthetic image-only page two.")
    save(image_only, "image-only.pdf")
    image_only.close()

    for name, text in (("boundary-19.pdf", "x" * 19), ("boundary-20.pdf", "x" * 20)):
        document = fitz.open()
        page = document.new_page(width=PAGE_RECT.width, height=PAGE_RECT.height)
        page.insert_text((72, 144), text, fontsize=20, fontname="helv")
        save(document, name)
        document.close()


if __name__ == "__main__":
    generate()
