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

## Findings on 0.3.2 build 10 (2026-11-16)

Same 112 pages, signed build 10. `row:all` is the share of label and amount
pairs that are both read and on the right row, over every pair in the truth.

| Run | amount | word | row:all |
| --- | --- | --- | --- |
| 200 DPI | 92.1 | 98.0 | 86.0 |
| 300 DPI | 91.9 | 97.4 | 84.5 |
| 400 DPI | 90.6 | 95.0 | 85.3 |
| Independent render, 300 DPI | 93.0 | 97.3 | 86.7 |
| Independent render, 300 DPI, language correction off | 92.9 | 97.3 | 86.6 |
| Independent render, 400 DPI | 92.0 | 94.6 | 86.3 |

**Resolution and language correction are not levers.** More pixels does not
help, and turning language correction off changes nothing. The 250 DPI
default stands. LocalOCR's own PDF rendering costs about one point of amount
recall against an independent renderer.

**Stability.** `low_read_monitor.py` read one scanned page 1,265 times over
12 hours, across 13 sleep and wake gaps, on mains and battery, with load up
to 228. Every read was identical. Short reads have only been seen in the
first minute after a new build is installed.

**Vision is confidently wrong.** Of 2,978 recognized lines that carry an
amount, 127 hold an amount that is not on the page, and 126 of those were
reported at full confidence (`amount_confidence.py`). Confidence cannot be
used to flag a doubtful amount.

**A second read can.** Reading each page at two resolutions and pairing the
lines by position (`two_read_agreement.py`):

| Reads | wrong amounts caught | right amounts flagged | flagged lines that are wrong |
| --- | --- | --- | --- |
| 300 and 200 DPI | 63.0% | 4.6% | 37.9% |
| 250 and 350 DPI | 58.9% | 5.1% | 30.0% |

A disagreement between two reads is the only signal found so far that an
amount may be wrong. It is now built as `--verify-amounts`; see the last section.

**Truth check.** Text drawn twice in one place (double-struck bold) is now
counted once. It made no difference on these documents, so the remaining
misses are recognition misses, not counting artifacts.

## What the wrong amounts are, and the amount check (2026-11-17)

**Most wrong amounts are one misreading.** The wrong-amount lines counted in
the experiments above used the benchmark's loose amount pattern. Looked at by
shape, 97 of 107 are the same thing: the amount is right up to its cents and
then runs into accented letters Vision made up (`99,999.9ął` where the page
has `99,999.90`). Only 10 are a clean amount with a wrong digit. The junk is
not tied to bold type or to a ruled line beside the amount, pinning the
recognition language to English does not remove it, and Vision's alternate
candidates do not hold the clean amount (141 of 148 checked).

**The amount check (`--verify-amounts`), as shipped.**
`verify_amounts_check.py` at 250 DPI with a second read at 350:

| | count | outcome |
| --- | --- | --- |
| Garbled amounts missing digits | 94 | 63 given a second reading, all 63 right; 31 marked unconfirmed |
| Clean amounts read right | 2,818 | 53 marked (1.9%) |
| Clean amounts read wrong | 10 | none marked |

The check repairs the common misreading. It does not catch a digit misread
the same way twice. Time on these pages: 19 s without it, 35 s with it.
Because every second reading offered for a garbled amount was right, doing
this by default for pages with garbled amounts is the next candidate.
