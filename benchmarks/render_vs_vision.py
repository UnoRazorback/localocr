"""Separate the PDF renderer from Vision: recognize one page three ways.
1. localocr ocr (LocalOCR renders the PDF page with PDFKit/CoreGraphics)
2. PyMuPDF renders the page to PNG, then `localocr image` recognizes the PNG
3. embedded text layer (truth)
Also lists the page's fonts and whether each is embedded. Counts only.
usage: render_vs_vision.py <cli> <pdf> <page>"""
import json
import os
import re
import subprocess
import sys
import tempfile

import fitz

cli, pdf, number = sys.argv[1], sys.argv[2], int(sys.argv[3])
WORD = re.compile(r"[A-Za-z]{3,}")
AMOUNT = re.compile(r"\d{1,3}(?:,\d{3})+(?:\.\d{2})?|\d+\.\d{2}")
doc = fitz.open(pdf)
page = doc[number - 1]
truth = page.get_text()
print("truth: words", len(WORD.findall(truth)), "amounts", len(AMOUNT.findall(truth)))

out = subprocess.run([cli, "ocr", pdf, "--pages", str(number), "--dpi", "300", "--force-ocr", "--no-cache", "--json"], capture_output=True)
text = json.loads(out.stdout)["pages"][0]["text"]
print("localocr render + Vision: words", len(WORD.findall(text)), "amounts", len(AMOUNT.findall(text)))

with tempfile.TemporaryDirectory() as folder:
    png = os.path.join(folder, "page.png")
    page.get_pixmap(dpi=300, alpha=False).save(png)
    out = subprocess.run([cli, "image", png, "--json"], capture_output=True)
    try:
        data = json.loads(out.stdout)
        text2 = data.get("text") or data["pages"][0]["text"]
        print("PyMuPDF render + Vision:  words", len(WORD.findall(text2)), "amounts", len(AMOUNT.findall(text2)))
    except Exception as error:
        print("image command failed:", type(error).__name__, out.stderr.decode()[-200:])

print("fonts on page (name, type, embedded):")
for font in page.get_fonts(full=True):
    xref, ext, ftype, basefont = font[0], font[1], font[2], font[3]
    print("  ", basefont, ftype, "embedded" if ext != "n/a" else "NOT EMBEDDED")
annots = list(page.annots() or [])
widgets = list(page.widgets() or [])
print("annotations", len(annots), "form fields", len(widgets), "optional content", bool(doc.get_ocgs()))
