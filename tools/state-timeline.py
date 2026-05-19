#!/usr/bin/env python3
"""
state-timeline.py  —  pivot widget-state log lines into a per-state CSV timeline.

Usage:
    python3 tools/state-timeline.py <logfile>  >  output.csv

Input format (one line per transition):
    widget-state: <ISO8601> <prev>→<next> reason=<reason>

Output CSV:
    timestamp, prev, next, reason, idle, warming, counting, waiting, wrapping, recovering, dismissed
    ^ marker (^) placed in the column for the active 'next' state.
    v marker (v) placed in the column for the exiting 'prev' state.
"""

import sys
import csv
import re
from datetime import datetime

STATES = ["idle", "warming", "counting", "waiting", "wrapping", "recovering", "dismissed"]

LINE_RE = re.compile(
    r"widget-state:\s+(\S+)\s+(\w+)→(\w+)\s+reason=(\S+)"
)


def parse_log(path: str):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            m = LINE_RE.search(raw.strip())
            if not m:
                continue
            ts_str, prev, nxt, reason = m.group(1), m.group(2), m.group(3), m.group(4)
            markers = {}
            for s in STATES:
                if s == nxt:
                    markers[s] = "^"
                elif s == prev:
                    markers[s] = "v"
                else:
                    markers[s] = ""
            rows.append({
                "timestamp": ts_str,
                "prev": prev,
                "next": nxt,
                "reason": reason,
                **markers,
            })
    return rows


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 state-timeline.py <logfile>", file=sys.stderr)
        sys.exit(1)
    rows = parse_log(sys.argv[1])
    fieldnames = ["timestamp", "prev", "next", "reason"] + STATES
    writer = csv.DictWriter(sys.stdout, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)


if __name__ == "__main__":
    main()
