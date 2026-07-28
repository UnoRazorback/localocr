"""macOS platform guard.

Apple's Vision framework (via pyobjc) only exists on macOS. Every entry point
must call ensure_macos() before importing anything that touches Vision/Quartz,
so a non-mac host gets one clear error instead of a cryptic ImportError deep
in pyobjc's bridge.
"""

import platform
import sys


def ensure_macos() -> None:
    system = platform.system()
    if system != "Darwin":
        sys.stderr.write(
            "ocr_service requires macOS: it OCRs pages with Apple's Vision "
            f"framework, which does not exist on {system}. Run this on a Mac.\n"
        )
        sys.exit(1)
