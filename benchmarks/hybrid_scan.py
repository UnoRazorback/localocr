#!/usr/bin/env python3
"""Find scanned pages that LocalOCR would skip because they carry a little embedded text.

LocalOCR treats a page as searchable when its embedded text has 20 or more
characters and then returns that text without running OCR. A scanned page
with only a stamp, header, footer or Bates number in real text passes that
test, so the scanned body would never be read.

For each PDF: counts pages that are a full-page image, are "searchable" by
that rule, and have little embedded text. With --cli, OCRs up to --sample of
those pages and reports how many words OCR finds versus the embedded text.
Counts only; no document text is printed.
usage: hybrid_scan.py [--cli path] [--sample N] file.pdf ...
"""
import argparse
import json
import re
import subprocess

import fitz

WORD = re.compile(r"[A-Za-z]{3,}")
AMOUNT = re.compile(r"\d{1,3}(?:,\d{3})+(?:\.\d{2})?|\d+\.\d{2}")
parser = argparse.ArgumentParser()
parser.add_argument("pdfs", nargs="+")
parser.add_argument("--cli")
parser.add_argument("--sample", type=int, default=4)
parser.add_argument(
    "--default-path",
    action="store_true",
    help="run the engine as clients do (no --force-ocr) to show what it returns for these pages today",
)
args = parser.parse_args()

grand = {"pages": 0, "image_pages": 0, "skipped_scans": 0, "ocr_only": 0}
print(f"{'document':<50}{'pages':>6}{'scan':>6}{'no-text':>8}{'at-risk':>8}  native->ocr words (amounts) on sampled at-risk pages")
for path in args.pdfs:
    try:
        doc = fitz.open(path)
    except Exception as error:
        print(path[:48], "open failed", type(error).__name__)
        continue
    image_pages = ocr_only = 0
    at_risk = []
    for index in range(doc.page_count):
        page = doc[index]
        area = abs(page.rect)
        blocks = page.get_text("dict")["blocks"]
        if not any(b.get("type") == 1 and abs(fitz.Rect(b["bbox"]) & page.rect) / area > 0.7 for b in blocks):
            continue
        image_pages += 1
        text = page.get_text()
        characters = len(re.sub(r"\s", "", text))
        if characters < 20:
            ocr_only += 1
        elif len(WORD.findall(text)) < 40:
            at_risk.append((index + 1, len(WORD.findall(text)), len(AMOUNT.findall(text))))
    detail = ""
    if args.cli and at_risk:
        step = max(1, len(at_risk) // args.sample)
        sample = at_risk[::step][: args.sample]
        spec = ",".join(str(n) for n, _, _ in sample)
        command = [args.cli, "ocr", path, "--pages", spec, "--dpi", "300", "--no-cache", "--json"]
        if not args.default_path:
            command.insert(-2, "--force-ocr")
        out = subprocess.run(command, capture_output=True)
        try:
            returned = json.loads(out.stdout)["pages"]
            pages = {p["page"]: p["text"] for p in returned}
            methods = sorted({p["method"] for p in returned})
            detail = f"{methods} " + "; ".join(
                f"p{n}: {w}->{len(WORD.findall(pages.get(n, '')))} ({a}->{len(AMOUNT.findall(pages.get(n, '')))})"
                for n, w, a in sample
            )
        except Exception as error:
            detail = f"ocr failed: {type(error).__name__}"
    name = path.rsplit("/", 1)[-1]
    print(f"{name[:48]:<50}{doc.page_count:>6}{image_pages:>6}{ocr_only:>8}{len(at_risk):>8}  {detail}")
    grand["pages"] += doc.page_count
    grand["image_pages"] += image_pages
    grand["skipped_scans"] += len(at_risk)
    grand["ocr_only"] += ocr_only
print("TOTAL", grand)
