#!/usr/bin/env python3
"""Watch for transient low reads.

Recognizes the same scanned page over and over and records how much text came
back each time, together with the state of the Mac (load, thermal pressure,
power source, display sleep, memory pressure). The aim is to catch the moment
a read comes back short and see what the machine was doing.

Writes one CSV line per read. Counts only; no document text.
usage: low_read_monitor.py <cli> <pdf> <page> <out.csv> [interval seconds] [hours]
"""
import csv
import json
import os
import re
import subprocess
import sys
import time

cli, pdf, page, out = sys.argv[1:5]
interval = float(sys.argv[5]) if len(sys.argv) > 5 else 20
hours = float(sys.argv[6]) if len(sys.argv) > 6 else 12


def run(*command):
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""


def machine_state():
    therm = run("/usr/bin/pmset", "-g", "therm")
    limit = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", therm)
    batt = run("/usr/bin/pmset", "-g", "batt")
    source = "ac" if "AC Power" in batt else "battery" if "Battery Power" in batt else "?"
    display = run("/usr/bin/pmset", "-g", "powerstate", "IODisplayWrangler")
    display_state = re.search(r"IODisplayWrangler\s+\S+\s+(\d+)", display)
    pressure = run("/usr/bin/memory_pressure", "-Q")
    free = re.search(r"free percentage:\s*(\d+)", pressure)
    low_power = "1" if re.search(r"lowpowermode\s+1", run("/usr/bin/pmset", "-g")) else "0"
    return [
        f"{os.getloadavg()[0]:.1f}",
        limit.group(1) if limit else "",
        source,
        display_state.group(1) if display_state else "",
        free.group(1) if free else "",
        low_power,
    ]


deadline = time.time() + hours * 3600
new = not os.path.exists(out)
with open(out, "a", newline="") as handle:
    writer = csv.writer(handle)
    if new:
        writer.writerow(["time", "seconds", "lines", "chars", "mean_confidence", "load1", "cpu_speed_limit", "power", "display_state", "mem_free_pct", "low_power_mode"])
    while time.time() < deadline:
        started = time.time()
        proc = subprocess.run([cli, "ocr", pdf, "--pages", page, "--dpi", "300", "--force-ocr", "--no-cache", "--detail", "--json"], capture_output=True)
        elapsed = time.time() - started
        try:
            p = json.loads(proc.stdout)["pages"][0]
            lines = p.get("lines") or []
            chars = len(re.sub(r"\s", "", p["text"]))
            confidence = sum(l["confidence"] for l in lines) / len(lines) if lines else 0
            row = [len(lines), chars, f"{confidence:.3f}"]
        except Exception:
            row = ["error", proc.returncode, ""]
        writer.writerow([time.strftime("%Y-%m-%dT%H:%M:%S"), f"{elapsed:.2f}", *row, *machine_state()])
        handle.flush()
        time.sleep(max(0, interval - (time.time() - started)))
