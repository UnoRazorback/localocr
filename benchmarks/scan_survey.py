#!/usr/bin/env python3
"""Does the garbled-cents misreading show up on true scans?

Finds PDFs in a folder whose pages are pictures with no text layer, reads a
sample of those pages with the amount check on, and counts amounts, garbled
amounts and marks. There is no truth for a scan, so this measures how often
the misreading appears and what the second read does about it.

Prints counts only. usage: scan_survey.py <cli> <pdf folder> [pages per file] [max files]
"""
import collections
import json
import os
import re
import subprocess
import sys
import time

import fitz

cli, root = sys.argv[1], sys.argv[2]
per_file = int(sys.argv[3]) if len(sys.argv) > 3 else 6
max_files = int(sys.argv[4]) if len(sys.argv) > 4 else 80

CLEAN = re.compile(
    r"(?<![A-Za-z0-9.,])(\d{1,3}(?:,\d{3})+(?:\.\d{2})?|\d+\.\d{2})(?![.,]?\d)(?![A-Za-z])"
    r"( \[second read: [^\]]*\]| \[not confirmed by second read\])?"
)
GARBLED = re.compile(
    r"(?<![A-Za-z0-9.,])(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{0,2}[^\x00-\x7f\W]+"
    r"( \[second read: [^\]]*\]| \[not confirmed by second read\])?"
)


def scanned_pages(path):
    """1-indexed pages that are a picture with no text layer."""
    try:
        pdf = fitz.open(path)
    except Exception:
        return None
    if pdf.needs_pass:
        return None
    found = []
    for index in range(min(len(pdf), 60)):
        page = pdf[index]
        if len(page.get_text("text").strip()) < 20 and page.get_images():
            found.append(index + 1)
    return found


files = sorted(
    (os.path.join(root, name) for name in os.listdir(root) if name.lower().endswith(".pdf")),
    key=os.path.getmtime, reverse=True,
)
totals = collections.Counter()
per_doc_garbled = []
started = time.time()
for path in files:
    if totals["files read"] >= max_files:
        break
    totals["pdfs looked at"] += 1
    pages = scanned_pages(path)
    if not pages:
        continue
    step = max(1, len(pages) // per_file)
    sample = pages[::step][:per_file]
    proc = subprocess.run(
        [cli, "ocr", path, "--pages", ",".join(map(str, sample)), "--verify-amounts", "--no-cache", "--json"],
        capture_output=True, timeout=900,
    )
    if proc.returncode not in (0, 3):
        totals["files that failed"] += 1
        continue
    result = json.loads(proc.stdout)
    totals["files read"] += 1
    garbled_here = 0
    for page in result["pages"]:
        if page["method"] != "vision_ocr":
            continue
        totals["scanned pages read"] += 1
        text = page["text"]
        page_garbled = 0
        for match in GARBLED.finditer(text):
            page_garbled += 1
            mark = match.group(1) or ""
            kind = "given a second reading" if "second read:" in mark else "marked unconfirmed" if mark else "unmarked"
            totals["garbled amounts " + kind] += 1
        for _, mark in CLEAN.findall(text):
            totals["clean amounts"] += 1
            if mark:
                totals["clean amounts marked"] += 1
        if page_garbled:
            totals["pages with a garbled amount"] += 1
        if CLEAN.search(text) or page_garbled:
            totals["pages with amounts"] += 1
        garbled_here += page_garbled
    totals["unchecked pages"] += len(result["amount_check"]["unchecked_pages"])
    totals["failed pages"] += len(result["failed_pages"])
    if garbled_here:
        per_doc_garbled.append(garbled_here)
for key in sorted(totals):
    print(f"{totals[key]:6d}  {key}")
print("files with garbled amounts:", len(per_doc_garbled), "counts per file:", sorted(per_doc_garbled, reverse=True)[:20])
print(f"elapsed {time.time() - started:.0f}s")
