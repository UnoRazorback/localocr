#!/usr/bin/env python3
"""How good are the marks `--verify-amounts` puts on amounts?

Runs the shipped check on the benchmark pages and compares every recognized
amount with the page's embedded text: how many wrong amounts carry a mark,
how many right ones do, what happens to garbled amounts, and what the check
costs in time.

Prints counts only. usage: verify_amounts_check.py <report.json> <cli> <pdf folder> [dpi]
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bench", os.path.join(here, "realdoc_benchmark.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
import fitz  # noqa: E402

MARKED = re.compile(
    r"(?<![A-Za-z0-9.,])(\d{1,3}(?:,\d{3})+(?:\.\d{2})?|\d+\.\d{2})(?![.,]?\d)(?![A-Za-z])"
    r"( \[second read: [^\]]*\]| \[not confirmed by second read\])?"
)


GARBLED = re.compile(
    r"(?<![A-Za-z0-9.,])(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{0,2}[^\x00-\x7f]+"
    r"( \[second read: ([^\]]*)\]| \[not confirmed by second read\])?"
)


def read(cli, path, pages, dpi, verify):
    command = [cli, "ocr", path, "--pages", ",".join(map(str, pages)), "--dpi", str(dpi),
               "--force-ocr", "--no-cache", "--json"]
    if verify:
        command.append("--verify-amounts")
    started = time.time()
    proc = subprocess.run(command, capture_output=True, timeout=1200)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode(errors="replace")[-300:])
    return json.loads(proc.stdout), time.time() - started


def main():
    report, cli, root = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
    dpi = int(sys.argv[4]) if len(sys.argv) > 4 else 250
    counts = {(v, m): 0 for v in ("right", "wrong") for m in ("marked", "plain")}
    garbled = {"second read right": 0, "second read wrong": 0, "marked unconfirmed": 0, "unmarked": 0}
    plain_seconds = check_seconds = 0.0
    reported = unchecked = 0
    for document in report["documents"]:
        pages = [p["page"] for p in document["pages"]
                 if p.get("amount_recall") is not None and not p["image_backed"]]
        if not pages:
            continue
        path = os.path.join(root, document["file"])
        pdf = fitz.open(path)
        _, seconds = read(cli, path, pages, dpi, verify=False)
        plain_seconds += seconds
        result, seconds = read(cli, path, pages, dpi, verify=True)
        check_seconds += seconds
        reported += result["amount_check"]["flagged_amounts"]
        unchecked += len(result["amount_check"]["unchecked_pages"])
        for page in result["pages"]:
            truth = bench.truth_for(pdf[page["page"] - 1])
            if not truth:
                continue
            known = set(bench.amounts(truth["text"]))
            for match in GARBLED.finditer(page["text"]):
                if match.group(2):
                    right = match.group(2).replace(",", "") in known
                    garbled["second read right" if right else "second read wrong"] += 1
                else:
                    garbled["marked unconfirmed" if match.group(1) else "unmarked"] += 1
            for amount, mark in MARKED.findall(page["text"]):
                verdict = "right" if amount.replace(",", "") in known else "wrong"
                counts[(verdict, "marked" if mark else "plain")] += 1
    print(f"amount check at {dpi} DPI")
    for verdict in ("right", "wrong"):
        marked, plain = counts[(verdict, "marked")], counts[(verdict, "plain")]
        print(f"{verdict:<5} amounts {marked + plain:5d}  marked {marked:4d}  "
              f"({100 * marked / max(1, marked + plain):.1f}%)")
    marked_total = counts[("right", "marked")] + counts[("wrong", "marked")]
    print(f"of marked amounts, {100 * counts[('wrong', 'marked')] / max(1, marked_total):.1f}% are wrong")
    print("garbled amounts (cents run into made-up letters):", garbled)
    print(f"amount_check reported {reported} marks, {unchecked} unchecked pages")
    print(f"time: {plain_seconds:.0f}s without the check, {check_seconds:.0f}s with it")


if __name__ == "__main__":
    main()
