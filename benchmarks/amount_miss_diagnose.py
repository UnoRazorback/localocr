#!/usr/bin/env python3
"""Classify why amounts in the truth layer were not found in the OCR text.

Prints categories and masked shapes only (digits shown as 9), never values.
usage: amount_miss_diagnose.py <report.json> <cli> <downloads dir> [max_pages]
"""
import collections
import importlib.util
import json
import os
import re
import sys

spec = importlib.util.spec_from_file_location("bench", os.path.join(os.path.dirname(os.path.abspath(__file__)), "realdoc_benchmark.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
import fitz  # noqa: E402

report, cli, root = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
limit = int(sys.argv[4]) if len(sys.argv) > 4 else 25
NUMBERISH = re.compile(r"[\d][\d,.\s]*[\d]|\d")


def mask(token: str) -> str:
    return re.sub(r"\d", "9", token)


def distance(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[-1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


pages = sorted(
    ((p["amount_recall"], d["file"], p["page"]) for d in report["documents"] for p in d["pages"]
     if p.get("amount_recall") is not None and p["amount_recall"] < 100 and not p["image_backed"]),
)[:limit]
seen, categories, shapes = set(), collections.Counter(), collections.Counter()
for _, name, number in pages:
    if (name.replace("_", "").replace(" ", ""), number) in seen:
        continue
    seen.add((name.replace("_", "").replace(" ", ""), number))
    path = os.path.join(root, name)
    truth = bench.truth_for(fitz.open(path)[number - 1])
    result, _ = bench.run_cli(cli, path, [number], 300, 300)
    text = result["pages"][0]["text"]
    have = collections.Counter(bench.amounts(text))
    raw_numbers = [re.sub(r"\s", "", m) for m in NUMBERISH.findall(text)]
    squeezed = re.sub(r"[\s,]", "", text)
    for token, count in collections.Counter(bench.amounts(truth["text"])).items():
        for _ in range(count - min(count, have.get(token, 0))):
            digits = token.replace(".", "")
            if token in squeezed:
                categories["present but split by spaces or odd commas"] += 1
            elif digits in re.sub(r"[\s,.]", "", text):
                categories["digits present, decimal point lost or moved"] += 1
                near = min(raw_numbers, key=lambda r: distance(r.replace(",", ""), token), default="")
                shapes[f"{mask(token)} -> {mask(near)}"] += 1
            else:
                near = min(raw_numbers, key=lambda r: distance(re.sub(r"[,.]", "", r), digits), default="")
                gap = distance(re.sub(r"[,.]", "", near), digits) if near else 99
                if gap <= 1:
                    categories["one digit wrong, missing or extra"] += 1
                elif gap <= 2:
                    categories["two digits off"] += 1
                else:
                    categories["not found on page"] += 1
print("pages examined:", len(seen))
for name, count in categories.most_common():
    print(f"{count:5d}  {name}")
print("decimal-point shapes:")
for shape, count in shapes.most_common(8):
    print(f"{count:5d}  {shape}")
