#!/usr/bin/env python3
"""Stand-in for the `localocr` CLI, used only to test the benchmark tools.

It "recognizes" a page by reading the PDF's own words, so the benchmark's
scoring can be checked without Apple Vision. FAKE_LOCALOCR_MODE selects how
the page text is laid out:

  rows     each table row on one line (cells joined with " | ")
  columns  one word per line, read column by column, as plain Vision output
  drop     like rows, but the last amount on the page is missing
"""
import json
import os
import re
import sys

import fitz

AMOUNT = re.compile(r"\d{1,3}(?:,\d{3})+(?:\.\d{2})?|\d+\.\d{2}")


def page_result(page, number, mode):
    words = [w for w in page.get_text("words") if w[3] > w[1]]
    width, height = page.rect.width, page.rect.height
    lines = [
        {
            "text": w[4],
            "confidence": 1.0,
            "x": w[0] / width,
            "y": 1 - w[3] / height,
            "width": (w[2] - w[0]) / width,
            "height": (w[3] - w[1]) / height,
        }
        for w in words
    ]
    if mode == "columns":
        ordered = sorted(words, key=lambda w: (round(w[0] / 150), w[1]))
        text = "\n".join(w[4] for w in ordered)
    else:
        rows = {}
        for w in words:
            rows.setdefault(round(w[1]), []).append(w)
        row_texts = [" | ".join(w[4] for w in sorted(row, key=lambda w: w[0])) for _, row in sorted(rows.items())]
        if mode == "drop":
            for index in range(len(row_texts) - 1, -1, -1):
                found = AMOUNT.findall(row_texts[index])
                if found:
                    row_texts[index] = row_texts[index].replace(found[-1], "")
                    break
        text = "\n".join(row_texts)
    return {"page": number, "method": "vision_ocr", "text": text, "lines": lines}


def main():
    arguments = sys.argv[1:]
    mode = os.environ.get("FAKE_LOCALOCR_MODE", "rows")
    if arguments[0] != "ocr":
        print("unsupported", file=sys.stderr)
        return 2
    document = fitz.open(arguments[1])
    pages = [int(p) for p in arguments[arguments.index("--pages") + 1].split(",")]
    result = {
        "source_path": arguments[1],
        "source_sha256": "0" * 64,
        "pages": [page_result(document[n - 1], n, mode) for n in pages],
        "failed_pages": [],
        "empty_ocr_pages": [],
        "rotated_ocr_pages": {},
    }
    json.dump(result, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
