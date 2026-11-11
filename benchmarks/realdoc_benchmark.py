#!/usr/bin/env python3
"""Real-document OCR accuracy benchmark for LocalOCR.

Ground truth is the PDF's own embedded text layer (read with PyMuPDF). Each
sampled page is re-recognized with Apple Vision through the `localocr` CLI
(`--force-ocr --no-cache`) and scored against that truth:

* amount recall  - share of dollar-style amounts in the truth found in the OCR
* word recall    - share of label words (3+ letters) found in the OCR
* row integrity  - share of (label row, amount) pairs whose amount lands on an
                   OCR text line together with most of that row's label words

Row integrity is reported twice: for the plain `text` the engine returns, and
for the same Vision lines re-assembled into rows from their geometry.

Everything stays on this Mac. Reports hold file names, page numbers and
scores only - never document text or amounts.

Limits: pages with an embedded text layer are mostly born-digital, so they are
cleaner than a true scan. Pages whose text layer sits on top of a full-page
image are tagged `image_backed`; their "truth" may itself be someone's OCR.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import statistics
import subprocess
import sys
import time

import fitz  # PyMuPDF

AMOUNT = re.compile(r"\d{1,3}(?:,\d{3})+(?:\.\d{2})?|\d+\.\d{2}")
WORD = re.compile(r"[A-Za-z]{3,}")


def amounts(text: str) -> list[str]:
    return [m.replace(",", "") for m in AMOUNT.findall(text)]


def words(text: str) -> list[str]:
    return [w.lower() for w in WORD.findall(text)]


def cluster_rows(boxes):
    """boxes: (y0, y1, x0, text) with y growing downward. Same rule as the engine:
    two fragments share a row when their vertical overlap is at least half of
    the shorter one."""
    rows: list[list[tuple]] = []
    for box in sorted(boxes, key=lambda b: ((b[0] + b[1]) / 2, b[2])):
        for row in rows:
            if any(
                (min(box[1], o[1]) - max(box[0], o[0])) / max(1e-9, min(box[1] - box[0], o[1] - o[0])) >= 0.5
                for o in row
            ):
                row.append(box)
                break
        else:
            rows.append([box])
    return [" ".join(b[3] for b in sorted(row, key=lambda b: b[2])) for row in rows]


def truth_for(page) -> dict | None:
    if page.rotation != 0:
        return None
    layout = page.get_text("dict")
    lines = [l for b in layout["blocks"] if b.get("type") == 0 for l in b["lines"]]
    if not lines:
        return None
    upright = sum(1 for l in lines if abs(l["dir"][0] - 1) < 0.02 and abs(l["dir"][1]) < 0.02)
    if upright / len(lines) < 0.9:
        return None
    wl = page.get_text("words")
    if len(wl) < 40:
        return None
    boxes = [(w[1], w[3], w[0], w[4]) for w in wl if w[3] > w[1]]
    rows = cluster_rows(boxes)
    text = "\n".join(rows)
    if len(amounts(text)) < 2:
        return None
    area = abs(page.rect)
    image_backed = any(
        abs(fitz.Rect(b["bbox"]) & page.rect) / area > 0.7 for b in layout["blocks"] if b.get("type") == 1
    )
    return {"rows": rows, "text": text, "image_backed": image_backed}


def assemble_rows(lines) -> list[str]:
    # Vision geometry is normalized with the origin at the bottom-left.
    boxes = [(1 - (l["y"] + l["height"]), 1 - l["y"], l["x"], l["text"]) for l in lines if l["height"] > 0]
    return cluster_rows(boxes)


def recall(truth: list[str], found: list[str]) -> tuple[int, int]:
    have = collections.Counter(found)
    hit = 0
    for token, count in collections.Counter(truth).items():
        hit += min(count, have.get(token, 0))
    return hit, len(truth)


def row_integrity(truth_rows: list[str], ocr_lines: list[str]) -> tuple[int, int, int]:
    """Returns (kept, scored, amount_missing) over (row, amount) pairs."""
    indexed = [(set(amounts(l)), set(words(l))) for l in ocr_lines]
    kept = scored = missing = 0
    for row in truth_rows:
        labels = set(words(row))
        row_amounts = set(amounts(row))
        if not labels or not row_amounts:
            continue
        for amount in row_amounts:
            candidates = [w for a, w in indexed if amount in a]
            if not candidates:
                missing += 1
                continue
            scored += 1
            best = max(len(labels & w) / len(labels) for w in candidates)
            kept += best >= 0.6
    return kept, scored, missing


def run_cli(cli: str, path: str, pages: list[int], dpi: int, timeout: int) -> tuple[dict, float]:
    spec = ",".join(str(p) for p in pages)
    started = time.time()
    proc = subprocess.run(
        [cli, "ocr", path, "--pages", spec, "--dpi", str(dpi), "--force-ocr", "--no-cache", "--detail", "--json"],
        capture_output=True,
        timeout=timeout,
    )
    elapsed = time.time() - started
    if proc.returncode != 0:
        raise RuntimeError(f"localocr exit {proc.returncode}: {proc.stderr.decode(errors='replace')[-300:]}")
    return json.loads(proc.stdout), elapsed


def pct(pair) -> float | None:
    return round(100 * pair[0] / pair[1], 1) if pair[1] else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pdfs", nargs="+")
    parser.add_argument("--cli", required=True, help="path to the localocr binary under test")
    parser.add_argument("--out", required=True, help="where to write the JSON report")
    parser.add_argument("--max-pages", type=int, default=12, help="pages sampled per document")
    parser.add_argument("--dpi", type=int, default=300)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()

    report = {"cli": args.cli, "dpi": args.dpi, "documents": []}
    totals = collections.defaultdict(lambda: [0, 0])
    missing_total = 0
    for path in args.pdfs:
        entry = {"file": os.path.basename(path), "pages": []}
        report["documents"].append(entry)
        try:
            doc = fitz.open(path)
            truths = {}
            for index in range(doc.page_count):
                truth = truth_for(doc[index])
                if truth:
                    truths[index + 1] = truth
            entry["page_count"] = doc.page_count
            entry["eligible_pages"] = len(truths)
            if not truths:
                entry["skipped"] = "no upright text-layer pages with amounts"
                continue
            eligible = sorted(truths)
            step = max(1, len(eligible) // args.max_pages)
            sample = eligible[::step][: args.max_pages]
            result, elapsed = run_cli(args.cli, path, sample, args.dpi, args.timeout)
            entry["seconds_per_page"] = round(elapsed / len(sample), 2)
            entry["failed_pages"] = result.get("failed_pages", [])
            by_page = {p["page"]: p for p in result["pages"]}
            doc_totals = collections.defaultdict(lambda: [0, 0])
            for number in sample:
                truth, got = truths[number], by_page.get(number)
                if got is None:
                    entry["pages"].append({"page": number, "error": "no result"})
                    continue
                raw_lines = (got.get("text") or "").split("\n")
                rows = assemble_rows(got.get("lines") or [])
                raw_text = "\n".join(raw_lines)
                am = recall(amounts(truth["text"]), amounts(raw_text))
                wd = recall(words(truth["text"]), words(raw_text))
                rk, rs, rm = row_integrity(truth["rows"], raw_lines)
                ak, as_, am_missing = row_integrity(truth["rows"], rows)
                entry["pages"].append(
                    {
                        "page": number,
                        "image_backed": truth["image_backed"],
                        "amount_recall": pct(am),
                        "word_recall": pct(wd),
                        "row_integrity_text": pct((rk, rs)),
                        "row_integrity_rows": pct((ak, as_)),
                        "row_pairs": rs,
                        "amounts": am[1],
                    }
                )
                for key, pair in (("amount", am), ("word", wd), ("row_text", (rk, rs)), ("row_rows", (ak, as_))):
                    for bucket in (totals, doc_totals):
                        bucket[key][0] += pair[0]
                        bucket[key][1] += pair[1]
                missing_total += rm
            entry["summary"] = {k: pct(v) for k, v in doc_totals.items()}
        except Exception as error:  # keep going; one bad file must not sink the run
            entry["error"] = f"{type(error).__name__}: {str(error)[:200]}"

    report["overall"] = {k: pct(v) for k, v in totals.items()}
    report["overall_counts"] = {k: v for k, v in totals.items()}
    report["row_pairs_with_amount_missing"] = missing_total
    scored = [p for d in report["documents"] for p in d["pages"] if "amount_recall" in p]
    report["pages_scored"] = len(scored)
    if scored:
        report["worst_amount_pages"] = sorted(
            ({"file": d["file"], "page": p["page"], "amount_recall": p["amount_recall"]}
             for d in report["documents"] for p in d["pages"] if p.get("amount_recall") is not None),
            key=lambda x: x["amount_recall"],
        )[:10]
        rows_text = [p["row_integrity_text"] for p in scored if p["row_integrity_text"] is not None]
        if rows_text:
            report["median_row_integrity_text"] = statistics.median(rows_text)
    with open(args.out, "w") as handle:
        json.dump(report, handle, indent=2)

    print(f"{'document':<58}{'pages':>6}{'amount':>8}{'word':>7}{'row:text':>10}{'row:rows':>10}{'s/pg':>6}")
    for d in report["documents"]:
        s = d.get("summary")
        if not s:
            print(f"{d['file'][:56]:<58}  {d.get('skipped') or d.get('error')}")
            continue
        print(
            f"{d['file'][:56]:<58}{len(d['pages']):>6}{s.get('amount')!s:>8}{s.get('word')!s:>7}"
            f"{s.get('row_text')!s:>10}{s.get('row_rows')!s:>10}{d.get('seconds_per_page')!s:>6}"
        )
    o = report["overall"]
    print(f"{'OVERALL':<58}{report['pages_scored']:>6}{o.get('amount')!s:>8}{o.get('word')!s:>7}"
          f"{o.get('row_text')!s:>10}{o.get('row_rows')!s:>10}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
