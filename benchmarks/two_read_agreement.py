#!/usr/bin/env python3
"""Would a second read catch misread amounts?

Vision reports full confidence for wrong amounts, so confidence cannot flag
them. This reads each page at two resolutions, pairs the lines by position,
and asks: when an amount is wrong, do the two reads disagree? When it is
right, do they agree? If so, disagreement is a usable warning.

Prints counts only. usage: two_read_agreement.py <report.json> <cli> <pdf folder> [dpi_a] [dpi_b]
"""
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
dpi_a = int(sys.argv[4]) if len(sys.argv) > 4 else 300
dpi_b = int(sys.argv[5]) if len(sys.argv) > 5 else 200


def overlap(a, b):
    left, right = max(a["x"], b["x"]), min(a["x"] + a["width"], b["x"] + b["width"])
    bottom, top = max(a["y"], b["y"]), min(a["y"] + a["height"], b["y"] + b["height"])
    if right <= left or top <= bottom:
        return 0.0
    inter = (right - left) * (top - bottom)
    return inter / min(a["width"] * a["height"], b["width"] * b["height"])


counts = {("right", "agree"): 0, ("right", "differ"): 0, ("right", "unpaired"): 0,
          ("wrong", "agree"): 0, ("wrong", "differ"): 0, ("wrong", "unpaired"): 0}
for document in report["documents"]:
    pages = [p["page"] for p in document["pages"] if p.get("amount_recall") is not None and not p["image_backed"]]
    if not pages:
        continue
    path = os.path.join(root, document["file"])
    pdf = fitz.open(path)
    first, _ = bench.run_cli(cli, path, pages, dpi_a, 600)
    second, _ = bench.run_cli(cli, path, pages, dpi_b, 600)
    other = {p["page"]: p.get("lines") or [] for p in second["pages"]}
    for page in first["pages"]:
        truth = bench.truth_for(pdf[page["page"] - 1])
        if not truth:
            continue
        known = set(bench.amounts(truth["text"]))
        for line in page.get("lines") or []:
            found = bench.amounts(line["text"])
            if not found:
                continue
            verdict = "right" if all(a in known for a in found) else "wrong"
            partner = max(other.get(page["page"], []), key=lambda o: overlap(line, o), default=None)
            if partner is None or overlap(line, partner) < 0.5:
                counts[(verdict, "unpaired")] += 1
            elif bench.amounts(partner["text"]) == found:
                counts[(verdict, "agree")] += 1
            else:
                counts[(verdict, "differ")] += 1
print(f"reads at {dpi_a} and {dpi_b} DPI, amount lines from the {dpi_a} read")
for verdict in ("right", "wrong"):
    agree, differ, unpaired = (counts[(verdict, k)] for k in ("agree", "differ", "unpaired"))
    total = agree + differ + unpaired
    flagged = differ + unpaired
    print(f"{verdict:<5} total {total:5d}  agree {agree:5d}  differ {differ:4d}  unpaired {unpaired:4d}  flagged {100 * flagged / max(1, total):5.1f}%")
wrong_total = sum(counts[("wrong", k)] for k in ("agree", "differ", "unpaired"))
flag_total = sum(counts[(v, k)] for v in ("right", "wrong") for k in ("differ", "unpaired"))
wrong_flagged = counts[("wrong", "differ")] + counts[("wrong", "unpaired")]
print(f"of all flagged lines, {100 * wrong_flagged / max(1, flag_total):.1f}% are wrong; "
      f"a second read catches {100 * wrong_flagged / max(1, wrong_total):.1f}% of wrong amounts")
