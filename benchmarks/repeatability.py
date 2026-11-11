#!/usr/bin/env python3
"""Does LocalOCR return the same thing for the same page every time?

Runs the CLI several times on the same pages and prints, per page, how many
distinct results came back. Prints counts only, never text.
usage: repeatability.py <cli> <pdf> <pages> <runs> [extra cli flags...]
"""
import collections
import hashlib
import json
import re
import subprocess
import sys
import time

cli, pdf, pages, runs = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
extra = sys.argv[5:]
WORD = re.compile(r"[A-Za-z]{3,}")
seen = collections.defaultdict(list)
for run in range(runs):
    started = time.time()
    out = subprocess.run(
        [cli, "ocr", pdf, "--pages", pages, "--dpi", "300", "--force-ocr", "--no-cache", "--detail", "--json", *extra],
        capture_output=True,
    )
    result = json.loads(out.stdout)
    rotated = result.get("rotated_ocr_pages") or {}
    for page in result["pages"]:
        lines = page.get("lines") or []
        confidence = sum(l["confidence"] for l in lines) / len(lines) if lines else 0
        low = sum(l["confidence"] < 0.5 for l in lines)
        seen[page["page"]].append((
            len(lines),
            len(WORD.findall(page["text"])),
            round(confidence, 3),
            low,
            str(rotated.get(str(page["page"]), "-")),
            hashlib.sha256(page["text"].encode()).hexdigest()[:8],
        ))
    print(f"run {run + 1}: {time.time() - started:.1f}s failed={result.get('failed_pages')} empty={result.get('empty_ocr_pages')}", flush=True)
print("page | distinct results | (lines, words, mean confidence, low-confidence lines, rotation, text hash) x count")
for number in sorted(seen):
    counts = collections.Counter(seen[number])
    print(number, "|", len(counts), "|", "; ".join(f"{k} x{v}" for k, v in counts.most_common()))
