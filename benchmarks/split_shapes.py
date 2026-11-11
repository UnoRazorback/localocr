"""For amounts the benchmark counts as missed although their digits are on the page,
show how Vision wrote them. Digits are masked as 9; nothing else is printed.
usage: split_shapes.py <report.json> <cli> <pdf folder> [max_pages]"""
import collections
import importlib.util
import json
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bench", os.path.join(here, "realdoc_benchmark.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
import fitz  # noqa: E402

report, cli, root = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
limit = int(sys.argv[4]) if len(sys.argv) > 4 else 20
mask = lambda s: re.sub(r"\d", "9", s)
pages = sorted(
    (p["amount_recall"], d["file"], p["page"]) for d in report["documents"] for p in d["pages"]
    if p.get("amount_recall") is not None and p["amount_recall"] < 100 and not p["image_backed"]
)[:limit]
shapes, truth_shapes, seen = collections.Counter(), collections.Counter(), set()
for _, name, number in pages:
    key = (re.sub(r"[_ ]", "", name), number)
    if key in seen:
        continue
    seen.add(key)
    path = os.path.join(root, name)
    truth = bench.truth_for(fitz.open(path)[number - 1])
    result, _ = bench.run_cli(cli, path, [number], 300, 300)
    text = result["pages"][0]["text"]
    have = collections.Counter(bench.amounts(text))
    for token, count in collections.Counter(bench.amounts(truth["text"])).items():
        if count <= have.get(token, 0):
            continue
        digits = token.replace(".", "")
        loose = re.compile(r"(?<![\d])" + r"[\s,.$|]*".join(map(re.escape, digits)) + r"(?![\d])")
        found = loose.search(text)
        if found:
            shapes[mask(found.group(0)).replace("\n", "<nl>")] += 1
        else:
            truth_shapes[mask(token)] += 1
print("pages", len(seen))
print("digits present, written as (top 25):")
for shape, count in shapes.most_common(25):
    print(f"{count:5d}  [{shape}]")
print("digits absent, truth shape (top 10):")
for shape, count in truth_shapes.most_common(10):
    print(f"{count:5d}  [{shape}]")
