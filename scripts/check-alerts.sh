#!/usr/bin/env python3
"""Every NSAlert the app shows goes through Alerts.

Sources/TranquilityApp/Alerts.swift records each alert as a Failure (so it
reaches Slack) and withholds a repeat of the same key inside ten minutes.
Ruled 19 Sep after five dialogs were found with no record anywhere but the
screen, and one landed ten times in fourteen minutes. A bare `NSAlert()`
shown anywhere else is the class coming back.

The check is per file: a file that constructs N alerts must hand at least N
to `Alerts.runModal` or `Alerts.beginSheet`. Construction and the call are a
few lines apart, so counting per statement would need a parser for nothing.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOOR = ROOT / "Sources/TranquilityApp/Alerts.swift"
BUILT = re.compile(r"\bNSAlert\(\)")
HANDED = re.compile(r"\bAlerts\.(runModal|beginSheet)\(")
SHOWN_DIRECTLY = re.compile(r"\.(runModal\(\)|beginSheetModal\(for:)")

bad = []
for path in sorted(ROOT.glob("Sources/**/*.swift")):
    if path == DOOR:
        continue
    text = path.read_text()
    built = len(BUILT.findall(text))
    if not built:
        continue
    handed = len(HANDED.findall(text))
    direct = len(SHOWN_DIRECTLY.findall(text))
    if handed < built or direct:
        bad.append(f"{path.relative_to(ROOT)}: builds {built} NSAlert, hands {handed} to Alerts, shows {direct} directly")

if bad:
    print("NSAlert shown outside Alerts (record it and gate it through Alerts.runModal / Alerts.beginSheet):", file=sys.stderr)
    for line in bad:
        print("  " + line, file=sys.stderr)
    sys.exit(1)
print("alerts: every NSAlert goes through Alerts")
