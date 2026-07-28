#!/usr/bin/env python3
"""Generate public, deterministic PDF fixtures for LocalOCRCore tests.

This generator intentionally depends only on PyMuPDF.  The text in every
fixture is synthetic so the repository contains no private document data.
"""

from pathlib import Path

import fitz


FIXTURES = Path(__file__).parents[1] / "tests" / "LocalOCRCoreTests" / "Fixtures"
PAGE_RECT = fitz.Rect(0, 0, 612, 792)  # US Letter at 72 points per inch.


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


def rasterized_text_page(text: str) -> fitz.Pixmap:
    source = fitz.open()
    page = source.new_page(width=PAGE_RECT.width, height=PAGE_RECT.height)
    page.insert_text((72, 144), text, fontsize=20, fontname="helv")
    pixmap = page.get_pixmap(matrix=fitz.Matrix(2, 2), alpha=False)
    source.close()
    return pixmap


def add_image_page(document: fitz.Document, text: str) -> None:
    page = document.new_page(width=PAGE_RECT.width, height=PAGE_RECT.height)
    page.insert_image(PAGE_RECT, pixmap=rasterized_text_page(text))


def generate() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)

    mixed = fitz.open()
    native_page = mixed.new_page(width=PAGE_RECT.width, height=PAGE_RECT.height)
    native_page.insert_text(
        (72, 144),
        "Synthetic native text has more than twenty characters.",
        fontsize=20,
        fontname="helv",
    )
    add_image_page(mixed, "Synthetic image-only text page.")
    save(mixed, "mixed.pdf")
    mixed.close()

    image_only = fitz.open()
    add_image_page(image_only, "Synthetic image-only page one.")
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
