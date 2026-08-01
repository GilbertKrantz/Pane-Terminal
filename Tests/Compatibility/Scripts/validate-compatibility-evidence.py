#!/usr/bin/env python3
"""Validate or regenerate Pane's checked-in compatibility dashboard."""

import datetime
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
SNAPSHOT = ROOT / "Tests/Compatibility/Snapshots/compatibility-evidence.json"
DASHBOARD = ROOT / "docs/compatibility.md"


def fail(message: str) -> None:
    print(f"compatibility evidence error: {message}", file=sys.stderr)
    raise SystemExit(1)


BEGIN_MARKER = "<!-- BEGIN GENERATED COMPATIBILITY MATRIX -->"
END_MARKER = "<!-- END GENERATED COMPATIBILITY MATRIX -->"
STATUSES = {"Pass", "Pending", "N/A"}
COLUMNS = ("launch", "input", "resize", "tabSwitch", "exit")


data = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
if data.get("schemaVersion") != 2:
    fail("unsupported schemaVersion")

dashboard = DASHBOARD.read_text(encoding="utf-8")
applications = set()
rows = [
    "| Application / behavior | Launch | Input | Resize | Tab switch | Exit | Evidence / notes |",
    "| --- | ---: | ---: | ---: | ---: | ---: | --- |",
]
for case in data.get("cases", []):
    application = case.get("application", "").strip()
    if not application or application in applications:
        fail(f"missing or duplicate application: {application!r}")
    applications.add(application)
    statuses = []
    for column in COLUMNS:
        status = case.get(column)
        if status not in STATUSES:
            fail(f"{application!r} has invalid {column} status {status!r}")
        statuses.append(status)
    if "Pass" in statuses:
        if not case.get("source"):
            fail(f"{application!r} is Pass without evidence source")
        try:
            datetime.date.fromisoformat(case["date"])
        except (KeyError, TypeError, ValueError):
            fail(f"{application!r} is Pass without an ISO evidence date")
    notes = case.get("notes", "").replace("|", "\\|").strip()
    if case.get("source"):
        evidence = f"`{case['source']}`"
        notes = f"{evidence}; {notes}" if notes else evidence
    rows.append(
        "| "
        + " | ".join(
            [
                application,
                *statuses,
                notes,
            ]
        )
        + " |"
    )

generated = "\n".join([BEGIN_MARKER, *rows, END_MARKER])
if BEGIN_MARKER not in dashboard or END_MARKER not in dashboard:
    fail("generated compatibility matrix markers are missing")
prefix, remainder = dashboard.split(BEGIN_MARKER, 1)
_, suffix = remainder.split(END_MARKER, 1)
expected_dashboard = prefix + generated + suffix

if "--write" in sys.argv[1:]:
    DASHBOARD.write_text(expected_dashboard, encoding="utf-8")
elif dashboard != expected_dashboard:
    fail(
        "docs/compatibility.md is stale; run "
        "Tests/Compatibility/Scripts/validate-compatibility-evidence.py --write"
    )

print(f"validated {len(applications)} compatibility evidence records")
