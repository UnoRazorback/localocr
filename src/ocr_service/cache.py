"""Disk cache for OCR results, keyed on file content hash + page number + DPI.

Per-page (not per-range) keying means two calls with overlapping but
different page_range values still share cache hits for the pages in common.
Only successful OCR results are cached; failures are always retried since
they may be transient (e.g. a momentarily locked file). Each entry stores the
full recognition record (text, orientation, per-line confidence/bbox) so a
cache hit can still serve include_lines=True requests.
"""

import json
from pathlib import Path

from . import pdf_utils


class OcrCache:
    def __init__(self, cache_dir: str | None = None):
        self.cache_dir = Path(cache_dir or (Path.home() / ".cache" / "ocr_service"))
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self._memory: dict[str, dict] = {}

    def file_key(self, path: str) -> str:
        return pdf_utils.sha256_file(path)

    def _entry_path(self, file_key: str, page_num: int, dpi: int) -> Path:
        return self.cache_dir / f"{file_key}_dpi{dpi}_p{page_num}.json"

    def _mem_key(self, file_key: str, page_num: int, dpi: int) -> str:
        return f"{file_key}:{dpi}:{page_num}"

    def get(self, file_key: str, page_num: int, dpi: int) -> dict | None:
        """Returns {"text": str, "orientation": str, "lines": [...]} or None on a miss."""
        mem_key = self._mem_key(file_key, page_num, dpi)
        if mem_key in self._memory:
            return self._memory[mem_key]
        entry_path = self._entry_path(file_key, page_num, dpi)
        if entry_path.exists():
            record = json.loads(entry_path.read_text())
            self._memory[mem_key] = record
            return record
        return None

    def set(self, file_key: str, page_num: int, dpi: int, record: dict) -> None:
        self._memory[self._mem_key(file_key, page_num, dpi)] = record
        self._entry_path(file_key, page_num, dpi).write_text(json.dumps(record))
