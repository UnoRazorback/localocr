"""CLI for testing OCR without an MCP client.

Usage:
    python -m ocr_service <file> [--pages 1-5] [--dpi 250]
    python -m ocr_service <file.pdf> --searchable [output.pdf]
"""

from . import platform_guard

platform_guard.ensure_macos()

import argparse  # noqa: E402
import json  # noqa: E402
import sys  # noqa: E402
from pathlib import Path  # noqa: E402

from . import core, pdf_utils, vision_ocr  # noqa: E402
from .cache import OcrCache  # noqa: E402

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".heic", ".tif", ".tiff", ".bmp", ".gif"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m ocr_service")
    parser.add_argument("file", help="PDF or image file to OCR")
    parser.add_argument("--pages", default=None, help='Page range, e.g. "1-5" or "3,7,12" (PDF only)')
    parser.add_argument("--dpi", type=int, default=250)
    parser.add_argument(
        "--searchable",
        metavar="OUTPUT",
        nargs="?",
        const="",
        default=None,
        help="Write a searchable PDF instead of printing text; optional output path",
    )
    parser.add_argument("--no-cache", action="store_true", help="Skip the on-disk OCR cache")
    parser.add_argument(
        "--force-ocr",
        action="store_true",
        help="OCR every page even if it already has a native text layer",
    )
    parser.add_argument(
        "--inspect",
        action="store_true",
        help="Check for an existing text layer only, no OCR (PDF only)",
    )
    parser.add_argument(
        "--detail",
        action="store_true",
        help="Include per-line confidence and bounding-box detail in the output",
    )
    args = parser.parse_args(argv)

    path = Path(args.file)
    if not path.exists():
        print(f"File not found: {path}", file=sys.stderr)
        return 1

    if path.suffix.lower() != ".pdf":
        with open(path, "rb") as f:
            text = vision_ocr.ocr_image_text(f.read())
        print(text)
        return 0

    if args.inspect:
        print(json.dumps(pdf_utils.inspect_pdf(str(path)), indent=2))
        return 0

    if args.searchable is not None:
        output_path = args.searchable or pdf_utils.default_searchable_output_path(str(path))
        failed_pages = pdf_utils.make_searchable_pdf(
            str(path), output_path, dpi=args.dpi, force_ocr=args.force_ocr
        )
        print(f"Wrote {output_path}")
        if failed_pages:
            print(f"Failed pages (no text layer): {failed_pages}", file=sys.stderr)
        return 0

    cache = None if args.no_cache else OcrCache()
    result = core.ocr_pdf_pages(
        str(path), args.pages, args.dpi, cache=cache, force_ocr=args.force_ocr, include_lines=args.detail
    )
    print(json.dumps(result, indent=2))
    if result["failed_pages"]:
        print(f"Failed pages: {result['failed_pages']}", file=sys.stderr)
    if result["empty_ocr_pages"]:
        print(f"Empty (no text found): {result['empty_ocr_pages']}", file=sys.stderr)
    if result["rotated_ocr_pages"]:
        print(f"Rotated pages: {result['rotated_ocr_pages']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
