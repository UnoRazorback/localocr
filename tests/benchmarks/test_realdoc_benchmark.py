"""The benchmark is the measuring stick for recognition changes, so its scoring is tested too."""
import json
import os
import subprocess
import sys
from pathlib import Path

import fitz
import pytest

ROOT = Path(__file__).resolve().parents[2]
BENCHMARK = ROOT / "benchmarks" / "realdoc_benchmark.py"
FAKE_CLI = Path(__file__).with_name("fake_localocr.py")

ROWS = [
    ("Mobilization and general conditions for sitework phase", "12", "25,740.00"),
    ("Concrete paving including joints and curing compound", "300", "6,435.00"),
    ("Underground storm drainage piping and structures complete", "45", "32,175.00"),
    ("Site electrical conduit trenching and backfill allowance", "7", "20,723.85"),
    ("Landscape irrigation sleeves beneath driveway crossings", "3", "3,042.90"),
    ("Erosion control maintenance through final stabilization", "1", "1,151.00"),
]


@pytest.fixture
def table_pdf(tmp_path):
    document = fitz.open()
    page = document.new_page(width=612, height=792)
    page.insert_text((72, 80), "Schedule of values summary", fontsize=11)
    for index, (label, quantity, amount) in enumerate(ROWS):
        y = 130 + index * 28
        page.insert_text((72, y), label, fontsize=9)
        page.insert_text((400, y), quantity, fontsize=9)
        page.insert_text((480, y), amount, fontsize=9)
    path = tmp_path / "table.pdf"
    document.save(path)
    return path


def run_benchmark(pdf, tmp_path, mode):
    out = tmp_path / f"report-{mode}.json"
    completed = subprocess.run(
        [sys.executable, str(BENCHMARK), "--cli", str(FAKE_CLI), "--out", str(out), str(pdf)],
        capture_output=True,
        text=True,
        env={**os.environ, "FAKE_LOCALOCR_MODE": mode},
    )
    assert completed.returncode == 0, completed.stderr
    return json.loads(out.read_text()), completed.stdout


# Catches the scorer calling column-ordered text correct: every amount is read,
# but none sits beside its label.
def test_column_ordered_text_scores_full_recall_and_no_row_integrity(table_pdf, tmp_path):
    report, _ = run_benchmark(table_pdf, tmp_path, "columns")
    overall = report["overall"]
    assert overall["amount"] == 100.0
    assert overall["word"] == 100.0
    assert overall["row_text"] == 0.0
    assert overall["row_all"] == 0.0
    # The same lines can still be rebuilt into rows from their geometry.
    assert overall["row_rows"] == 100.0


# Catches the scorer failing to credit row-joined text.
def test_row_joined_text_scores_full_row_integrity(table_pdf, tmp_path):
    report, stdout = run_benchmark(table_pdf, tmp_path, "rows")
    overall = report["overall"]
    assert overall["amount"] == 100.0
    assert overall["row_text"] == 100.0
    assert overall["row_all"] == 100.0
    assert "OVERALL" in stdout and "row:all" in stdout


# Catches a missing amount hiding inside row integrity, which only counts amounts that were found.
def test_missing_amount_lowers_recall_and_the_all_pairs_row_score(table_pdf, tmp_path):
    report, _ = run_benchmark(table_pdf, tmp_path, "drop")
    overall = report["overall"]
    assert overall["amount"] == pytest.approx(100 * 5 / 6, abs=0.1)
    assert overall["row_text"] == 100.0
    assert overall["row_all"] == pytest.approx(100 * 5 / 6, abs=0.1)
    assert report["row_pairs_with_amount_missing"] == 1


# Catches document text leaking into a report that is meant to hold scores only.
def test_report_holds_no_document_text(table_pdf, tmp_path):
    report, stdout = run_benchmark(table_pdf, tmp_path, "rows")
    serialized = json.dumps(report) + stdout
    for label, _, amount in ROWS:
        assert amount not in serialized
        assert label.split()[0] not in serialized
