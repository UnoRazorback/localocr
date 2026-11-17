#!/usr/bin/env python3
"""Do misread amounts come with lower Vision confidence?

For every recognized line that carries an amount, checks whether that amount
exists in the page's embedded text, and compares the confidence Vision gave to
lines whose amounts are right with lines whose amounts are not. If wrong
amounts cluster at low confidence, they can be flagged or re-read.

Prints counts only. usage: amount_confidence.py <report.json> <cli> <pdf folder> [dpi]
"""
import collections
import importlib.util
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bench", os.path.join(here, "realdoc_benchmark.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
import fitz  # noqa: E402

report, cli, root = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
dpi = int(sys.argv[4]) if len(sys.argv) > 4 else 300
BANDS = [(0.0, 0.3), (0.3, 0.5), (0.5, 0.8), (0.8, 0.95), (0.95, 0.999), (0.999, 1.01)]
right, wrong = collections.Counter(), collections.Counter()
heights_right, heights_wrong = [], []
for document in report["documents"]:
    pages = [p["page"] for p in document["pages"] if p.get("amount_recall") is not None and not p["image_backed"]]
    if not pages:
        continue
    path = os.path.join(root, document["file"])
    pdf = fitz.open(path)
    result, _ = bench.run_cli(cli, path, pages, dpi, 600)
    for page in result["pages"]:
        truth = bench.truth_for(pdf[page["page"] - 1])
        if not truth:
            continue
        known = set(bench.amounts(truth["text"]))
        for line in page.get("lines") or []:
            found = bench.amounts(line["text"])
            if not found:
                continue
            ok = all(a in known for a in found)
            band = next(i for i, (low, high) in enumerate(BANDS) if low <= line["confidence"] < high)
            (right if ok else wrong)[band] += 1
            (heights_right if ok else heights_wrong).append(line["height"])
total_right, total_wrong = sum(right.values()), sum(wrong.values())
print(f"amount lines: right {total_right}, not in truth {total_wrong}")
print("confidence band      right   wrong   share of band that is wrong")
for index, (low, high) in enumerate(BANDS):
    r, w = right[index], wrong[index]
    share = f"{100 * w / (r + w):.1f}%" if r + w else "-"
    print(f"{low:5.3f} - {min(high, 1.0):5.3f}   {r:7d} {w:7d}   {share}")
if heights_right and heights_wrong:
    median = lambda v: sorted(v)[len(v) // 2]
    print(f"median line height (fraction of page): right {median(heights_right):.4f}, wrong {median(heights_wrong):.4f}")
