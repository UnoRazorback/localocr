# Real-document benchmark

Scores LocalOCR's Apple Vision OCR against the text layer already embedded in
real PDFs. It answers one question with numbers: when a page is recognized
from pixels, how much of what matters for a financial review survives?

| Metric | Meaning |
| --- | --- |
| amount | share of dollar-style amounts in the PDF text found in the OCR text |
| word | share of label words (3+ letters) found in the OCR text |
| row:text | share of (label row, amount) pairs whose amount is on the same OCR text line as most of that row's labels |
| row:rows | the same, after rebuilding rows from the Vision line geometry (the ceiling for row:text) |

## Run

```sh
python benchmarks/realdoc_benchmark.py --cli /path/to/localocr --out report.json --max-pages 10 file1.pdf file2.pdf
python benchmarks/amount_miss_diagnose.py report.json /path/to/localocr /folder/with/the/pdfs
```

Needs PyMuPDF (`pip install pymupdf`). Nothing leaves the Mac. Reports hold
file names, page numbers and scores; the diagnosis prints categories and
digit-masked shapes. Keep reports out of the repository.

## Limits

- Truth comes from embedded text, so sampled pages are mostly born-digital and
  cleaner than a true scan. Treat the scores as an upper bound for scans.
- Pages with a text layer over a full-page image are tagged `image_backed`;
  their text layer may be another tool's OCR and is not reliable truth.
- Rotated pages and pages with sideways text are skipped.

## First results (2026-11-10)

112 pages from 16 construction documents (pay applications, change order
requests, a geotechnical report), 300 DPI.

| Build | amount | word | row:text | row:rows |
| --- | --- | --- | --- | --- |
| 0.3.1 build 8 (published) | 83.3 | 98.2 | 8.0 | 94.5 |
| with `TableRowTextAssembler` | 83.3 | 98.2 | 94.3 | 94.5 |

Amount recall on the 110 born-digital pages alone is 91.6. On the 27 weakest
of those, misses split as: 40% amount present but broken by spaces or commas,
26% not found, 20% decimal point lost or moved, 14% one or two digits off.
