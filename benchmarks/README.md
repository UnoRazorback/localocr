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

## Other tools

| Script | Question it answers |
| --- | --- |
| `realdoc_benchmark.py --renderer pymupdf` | Same scores with pages rendered independently and recognized as pictures, which takes LocalOCR's PDF renderer out of the measurement. |
| `repeatability.py` | Does the same page give the same result every time? |
| `render_vs_vision.py` | For one page: LocalOCR render + Vision, independent render + Vision, and the embedded text, plus the page's fonts. |
| `hybrid_scan.py` | Which scanned pages carry a little embedded text (stamp, envelope ID, header) and what OCR finds on them. |
| `amount_miss_diagnose.py`, `split_shapes.py` | Why amounts were counted as missed, with digits masked. |

## Findings after build 9 (2026-11-11)

**Scanned pages with a little embedded text were skipped.** A page counted as
searchable with 20 embedded characters, so a scanned page carrying only a
signing-envelope ID or stamp returned those few words and was never read. In
22 documents, 318 pages are full-page scans and 20 of them were at risk; on
build 9 the certified cover pages of two pay applications returned 5 words
where OCR reads about 280 words and 19 amounts. The engine now checks the
pixels whenever embedded text is under 400 characters and uses recognition
when it reads at least twice as much and at least 100 more characters. All
sampled at-risk pages now come back through OCR.

**Thousands commas read as periods.** Vision returned amounts such as
`99.999.99` for `99,999.99`. Recognized lines now restore grouping commas for
that exact shape; no digit is changed and references, versions and addresses
are left alone.

| Build | amount | word | row:text | amounts found and on the right row |
| --- | --- | --- | --- | --- |
| 0.3.2 build 9 | 83.3 | 97.4 | 94.3 | 81.5 |
| after these changes | 91.9 | 98.2 | 90.5 | 84.5 |

`row:text` is measured only over amounts that were found, so recovering 304
more amounts changed its population; the last column counts every label and
amount pair in the truth, found or not.

**Forced OCR on born-digital pages can lose text, and it varies.** Word
recall moved between runs on a few pages. Back-to-back runs are identical;
the change follows the state of the Mac, not the build. The same pictures
rendered independently are read in full, and CoreGraphics logs glyph-mapping
errors for those pages, whose fonts are standard and not embedded. This
affects `--force-ocr` on pages that already have text, which is what this
benchmark does and what clients normally do not. Leave `force_ocr` off unless
a page's embedded text is known to be wrong.

**Still open.** About 8% of amounts on these pages are still not matched:
repeated amounts recognized fewer times than they appear, and amounts whose
digits are missing or misread. Rendering independently gives the same amount
score, so these are recognition misses, not rendering.
