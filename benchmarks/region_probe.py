#!/usr/bin/env python3
"""Does reading a garbled amount's own spot again, enlarged, return the amount cleanly?

mode "truth": benchmark pages (born-digital, embedded text is the answer key).
mode "scans": picture-only pages from a folder (no answer key; counts clean readings that begin the same way).
Prints counts only.
usage: region_probe.py truth <report.json> <pdf folder> <bench dir> <probe.swift>
       region_probe.py scans <pdf folder> <probe.swift> [pages per file] [max files]
"""
import collections, importlib.util, json, os, re, subprocess, sys, tempfile
import fitz

GARBLED = re.compile(r"(?<![A-Za-z0-9.,])((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{0,2})[^\x00-\x7f\W]+")
CLEAN = re.compile(r"(?<![A-Za-z0-9.,])(?:\d{1,3}(?:,\d{3})+(?:\.\d{2})?|\d+\.\d{2})(?![.,]?\d)(?![A-Za-z])")
mode = sys.argv[1]
truths = {}
with tempfile.TemporaryDirectory() as folder:
    if mode == "truth":
        report, root, probe = json.load(open(sys.argv[2])), sys.argv[3], sys.argv[5]
        spec = importlib.util.spec_from_file_location("bench", os.path.join(sys.argv[4], "realdoc_benchmark.py"))
        bench = importlib.util.module_from_spec(spec); spec.loader.exec_module(bench)
        for di, document in enumerate(report["documents"]):
            pages = [p["page"] for p in document["pages"] if p.get("amount_recall") is not None and not p["image_backed"]]
            if not pages: continue
            pdf = fitz.open(os.path.join(root, document["file"]))
            for number in pages:
                truth = bench.truth_for(pdf[number - 1])
                if not truth: continue
                name = f"d{di:02d}-p{number:04d}.png"
                pdf[number - 1].get_pixmap(dpi=250, alpha=False).save(os.path.join(folder, name))
                truths[name] = set(bench.amounts(truth["text"]))
    else:
        root, probe = sys.argv[2], sys.argv[3]
        per_file = int(sys.argv[4]) if len(sys.argv) > 4 else 6
        max_files = int(sys.argv[5]) if len(sys.argv) > 5 else 80
        files = sorted((os.path.join(root, n) for n in os.listdir(root) if n.lower().endswith(".pdf")), key=os.path.getmtime, reverse=True)
        used = 0
        for fi, path in enumerate(files):
            if used >= max_files: break
            try:
                pdf = fitz.open(path)
                if pdf.needs_pass: continue
                scanned = [i for i in range(min(len(pdf), 60)) if len(pdf[i].get_text("text").strip()) < 20 and pdf[i].get_images()]
            except Exception:
                continue
            if not scanned: continue
            used += 1
            step = max(1, len(scanned) // per_file)
            for index in scanned[::step][:per_file]:
                pdf[index].get_pixmap(dpi=250, alpha=False).save(os.path.join(folder, f"f{fi:03d}-p{index + 1:04d}.png"))
    out = subprocess.run(["/usr/bin/swift", probe, folder], capture_output=True, text=True, timeout=5000,
                         env={**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"})
    if out.returncode != 0:
        print(out.stderr[-800:]); sys.exit(1)
tallies = collections.defaultdict(collections.Counter); total = 0
for row in out.stdout.splitlines():
    record = json.loads(row)
    known = truths.get(record["file"])
    for match in GARBLED.finditer(record["top"]):
        total += 1
        prefix = match.group(1).replace(",", "")
        for name, text in record["readings"].items():
            found = [a.replace(",", "") for a in CLEAN.findall(text)]
            same = [a for a in found if a.startswith(prefix) and len(a) - len(prefix) <= 2]
            if not same:
                verdict = "still garbled" if GARBLED.search(text) else "no amount that begins the same"
            elif known is None:
                verdict = "clean amount that begins the same"
            else:
                verdict = "clean and right" if any(a in known for a in same) else "clean but not on the page"
            tallies[name][verdict] += 1
print(f"{mode}: garbled amounts in the first reading: {total}")
for name in sorted(tallies):
    print(f"  {name:<14}", dict(sorted(tallies[name].items())))
